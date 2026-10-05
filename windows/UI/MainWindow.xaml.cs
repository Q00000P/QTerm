using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using QTermWin.Models;
using QTermWin.Sync;
using QTermWin.Terminal;
using QTermWin.Vault;
using QTermWin.Xui;
using Session = QTermWin.Models.Session;

namespace QTermWin.UI;

public partial class MainWindow : Window
{
    private readonly VaultRepo _repo = new();
    private SyncEngine? _sync;
    private TermBridge? _bridge;
    private readonly Dictionary<Guid, SshSessionController> _controllers = new();
    private readonly Dictionary<Guid, ServerMonitor> _monitors = new();
    private readonly Dictionary<Guid, MonitorStats> _lastStats = new();
    // Редактор — отдельное приложение QEditor.exe (мак-канон QTermEditor.app):
    // своя иконка/кнопка в таскбаре; файлы нод ходят по каналу, заливает QTerm
    private readonly EditorBridge _editor = new();
    private readonly List<ExternalEdit> _externalEdits = new();

    private sealed record ExternalEdit(System.IO.FileSystemWatcher Watcher, string Local,
        string Remote, Files.FileService Svc);
    private readonly System.Collections.ObjectModel.ObservableCollection<TabVM> _tabs = new();
    private Guid? _activeTab;
    private readonly Dictionary<Guid, SessState> _tabStates = new();
    private bool _broadcast;

    private sealed record NodeRow(Guid Id, string Name, string Address);

    public enum TabKind { Term }

    public sealed class TabVM : INotifyPropertyChanged
    {
        public Guid Id { get; init; }
        public TabKind Kind { get; init; }

        private string _name = "";
        public string Name { get => _name; set { _name = value; N(); N(nameof(Label)); } }

        private string _suffix = "";
        /// <summary>« ·2» у второй и следующих вкладок одной ноды.</summary>
        public string Suffix { get => _suffix; set { if (_suffix == value) return; _suffix = value; N(nameof(Label)); } }
        public string Label => _name + _suffix;

        private Brush _dot = Brushes.Orange;
        public Brush DotBrush { get => _dot; set { _dot = value; N(); } }

        private bool _active;
        public bool IsActive { get => _active; set { _active = value; N(nameof(TabBrush)); } }

        public Brush TabBrush => QTermShared.ThemeManager.Brush(IsActive ? "NodeTabActive" : "NodeTabIdle");

        /// <summary>Тема сменилась — перечитать кисти вкладки.</summary>
        public void ThemeChanged() => N(nameof(TabBrush));

        public event PropertyChangedEventHandler? PropertyChanged;
        private void N([CallerMemberName] string? p = null) =>
            PropertyChanged?.Invoke(this, new(p));
    }

    public MainWindow()
    {
        InitializeComponent();
        Title = BuildTitle();
        TabStrip.ItemsSource = _tabs;
        _tabs.CollectionChanged += (_, _) => RenumberTabs();
        Closing += (_, _) => { if (FilesCol.Width.Value > 0) RememberFilesWidth(); };
        _repo.Changed += () => RunOnUi(RefreshList);
        try { _repo.LoadOrInit(); }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Не удалось открыть локальный вейлт:\n" + ex.Message,
                "QTerm", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        _sync = new SyncEngine(_repo, Dispatcher);
        _sync.Status += (text, err) => RunOnUi(() =>
        {
            CountLabel.Text = $"Нод: {_repo.VisibleSessions.Count()} · синк: {text}";
        });
        Loaded += async (_, _) =>
        {
            await InitBridgeAsync();
            _sync.PullOnLaunch();
        };
    }

    private void RunOnUi(Action a)
    {
        if (Dispatcher.CheckAccess()) a();
        else Dispatcher.Invoke(a);
    }

    private async Task InitBridgeAsync()
    {
        _bridge = new TermBridge(Web);
        _bridge.Input += (id, data) =>
        {
            // Ввод всегда адресный; «Во все» работает по Enter целыми строками
            SshSessionController? c;
            lock (_controllers) _controllers.TryGetValue(id, out c);
            c?.Write(data);
        };
        _bridge.BroadcastCommand += (id, cmd) =>
        {
            if (!_broadcast) return;
            var bytes = System.Text.Encoding.UTF8.GetBytes(cmd + "\n");
            List<(Guid Tid, SshSessionController Ctl)> all;
            lock (_controllers) all = _controllers.Select(kv => (kv.Key, kv.Value)).ToList();
            foreach (var (tid, ctl2) in all)
                if (tid != id) ctl2.Write(bytes); // активная уже получила свой Enter
        };
        _bridge.Resized += (id, cols, rows) =>
        {
            SshSessionController? c;
            lock (_controllers) _controllers.TryGetValue(id, out c);
            c?.Resize(cols, rows);
        };
        _bridge.PrefixChanged += (id, prefix) => RunOnUi(() =>
        {
            if (prefix.Length == 0) { _bridge!.Suggest(id, "", Array.Empty<(string, bool)>()); return; }
            // Свои первые (count desc, lastUsed desc), словарь следом, до 6
            var own = _repo.VisibleCmdHistory
                .Where(kv => kv.Key.StartsWith(prefix, StringComparison.Ordinal) && kv.Key != prefix)
                .OrderByDescending(kv => kv.Value.Count)
                .ThenByDescending(kv => kv.Value.LastUsed ?? "", StringComparer.Ordinal)
                .Select(kv => kv.Key)
                .ToList();
            var dict = _repo.EffectiveDict()
                .Where(d => d.Cmd.StartsWith(prefix, StringComparison.Ordinal) && d.Cmd != prefix && !own.Contains(d.Cmd))
                .Select(d => d.Cmd);
            var items = own.Select(t => (t, true)).Concat(dict.Select(t => (t, false))).Take(6);
            _bridge!.Suggest(id, prefix, items);
        });
        _bridge.CommandEntered += (_, cmd) => RunOnUi(() => _repo.RecordCommand(cmd));
        // ВАЖНО: асинхронно. Модальное окно (ShowDialog) прямо внутри WebMessageReceived
        // оставляло WebView2 посреди обработки ввода — курсор мыши пропадал над окном
        _bridge.Hotkey += key => Dispatcher.InvokeAsync(() => HandleHotkey(key));
        _bridge.Cwd += (id, v, osc7) => Dispatcher.InvokeAsync(() => OnTermCwd(id, v, osc7));
        ApplyKeys(); // уйдёт в xterm по готовности моста (очередь _pending)
        _bridge.Ready += () => RunOnUi(ApplyTermTheme);
        QTermShared.ThemeManager.Changed += () => RunOnUi(OnThemeChanged);
        var st0 = Security.AppSettings.Load();
        if (st0.TermFontSize is { } tfs && tfs != 14)
            _bridge.Ready += () => RunOnUi(() => _bridge?.SetTermFontSize(tfs));
        if (st0.ScrollbackLines is { } sbl)
            _bridge.Ready += () => RunOnUi(() => _bridge?.SetScrollback(FontDialog.ClampScrollback(sbl)));
        _bridge.JsError += text => RunOnUi(() =>
            MessageBox.Show(this, "Ошибка терминальной страницы:\n" + text,
                "QTerm — JS", MessageBoxButton.OK, MessageBoxImage.Warning));
        _bridge.DeleteCommand += (_, cmd) => RunOnUi(() => _repo.DeleteCommand(cmd));
        _bridge.DictOp += (op, cmd) => RunOnUi(() =>
        {
            if (op == "add") _repo.AddDictEntry(cmd);
            else if (op == "hide") _repo.RemoveDictEntry(cmd);
            CountLabel.Text = op == "add" ? $"«{cmd}» в словаре" : $"«{cmd}» скрыт из словаря";
        });
        try { await _bridge.InitAsync(); }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                "WebView2 Runtime не инициализировался. Поставь Evergreen Runtime " +
                "(на Win11 есть из коробки).\n\n" + ex.Message,
                "QTerm", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // ── Горячие клавиши (настраиваются: ⋮ → Горячие клавиши…) ──

    private Dictionary<string, Gesture?> _keys = Hotkeys.Load();

    /// <summary>Раскладку — в xterm (там ловится при фокусе в терминале) и в подсказки кнопок.</summary>
    private void ApplyKeys()
    {
        _bridge?.SetKeys(_keys.Where(kv => kv.Value is not null)
            .Select(kv => (kv.Key, kv.Value!.Ctrl, kv.Value.Shift, kv.Value.Alt, kv.Value.Code)));
        GitButton.ToolTip = "Команды Git: добавить и править" +
            (_keys.GetValueOrDefault("git") is { } gq ? $"\nБыстрый вызов — {gq.Display}" : "\nБыстрый вызов — назначь хоткей в «Горячих клавишах»");
        SnippetsButton.ToolTip = Hint("Сниппеты и журнал команд", "snippets");
        FilesButton.ToolTip = Hint("Файловая панель", "files");
        ClearButton.ToolTip = Hint("Очистить экран и историю терминала", "clear");
    }

    private string Hint(string text, string id) =>
        _keys.GetValueOrDefault(id) is { } g ? $"{text} — {g.Display}" : text;

    private string KeyText(string id) => _keys.GetValueOrDefault(id)?.Display ?? "";

    private void ShowHotkeys()
    {
        if (new HotkeysWindow { Owner = this }.ShowDialog() != true) return;
        _keys = Hotkeys.Load();
        ApplyKeys();
    }

    private void HandleHotkey(string key)
    {
        switch (key)
        {
            case "dup": // дубль активной терминальной сессии
                if (ActiveTermTab() is { } tid)
                {
                    SshSessionController? c;
                    lock (_controllers) _controllers.TryGetValue(tid, out c);
                    if (c is not null) OpenSession(c.SessionRef);
                }
                break;
            case "close":
                if (_activeTab is { } id) CloseTab(id);
                break;
            case "next":
            case "prev":
                if (_tabs.Count > 0)
                {
                    var i = _tabs.ToList().FindIndex(t => t.Id == _activeTab);
                    var step = key == "next" ? 1 : -1;
                    i = i < 0 ? 0 : (i + step + _tabs.Count) % _tabs.Count;
                    ActivateTab(_tabs[i].Id);
                }
                break;
            case "git": ShowGitQuick(); break;
            case "gitedit": ShowGitCommands(); break;
            case "snippets": SnippetsButton_Click(SnippetsButton, new RoutedEventArgs()); break;
            case "journal": new CmdLogWindow(_repo) { Owner = this }.ShowDialog(); break;
            case "clear": ClearTerm_Click(this, new RoutedEventArgs()); break;
            case "broadcast": Broadcast_Click(this, new RoutedEventArgs()); break;
            case "reconnect": ReconnectNow_Click(this, new RoutedEventArgs()); break;
            case "files": FilesButton_Click(this, new RoutedEventArgs()); break;
            case "newnode": NodeAdd_Click(this, new RoutedEventArgs()); break;
            case "sync": SyncButton_Click(this, new RoutedEventArgs()); break;
            case "qeditor": _ = OpenScrapbookAsync(); break;
            case "xui": ShowXui(); break;
            case "nodeadd": AddNodeFromSelection(); break;
            case "hotkeys": ShowHotkeys(); break;
            default:
                if (key.StartsWith("tab", StringComparison.Ordinal) &&
                    int.TryParse(key[3..], out var n) && n >= 1 && n <= _tabs.Count)
                    ActivateTab(_tabs[n - 1].Id);
                break;
        }
    }

    private async Task OpenScrapbookAsync()
    {
        try { await _editor.NewDocAsync(); }
        catch (Exception ex)
        {
            MessageBox.Show(this, "QEditor: " + ex.Message, "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private Guid? ActiveTermTab() => _activeTab;

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        // Фокус в терминале — ловит xterm (op "keys") и шлёт через мост
        if (e.Handled || Web.IsKeyboardFocusWithin) return;
        var k = e.Key == Key.System ? e.SystemKey : e.Key;
        if (Hotkeys.CodeOf(k) is not { } code) return;
        var m = Keyboard.Modifiers;
        var id = Hotkeys.Find(_keys, m.HasFlag(ModifierKeys.Control), m.HasFlag(ModifierKeys.Shift),
            m.HasFlag(ModifierKeys.Alt), code);
        if (id is null or "copy" or "paste") return; // копипаста — только в терминале
        e.Handled = true;
        // модальные окна — не изнутри обработчика ввода
        Dispatcher.InvokeAsync(() => HandleHotkey(id));
    }

    private void Broadcast_Click(object sender, RoutedEventArgs e)
    {
        _broadcast = !_broadcast;
        _bridge?.SetBroadcast(_broadcast);
        PaintBroadcastButton();
        BroadcastButton.Content = _broadcast ? "Во все ●" : "Во все";
    }

    private void PaintBroadcastButton()
    {
        // «Во все» включён — красноватая кнопка; выключен — обычная (из стиля)
        if (_broadcast) BroadcastButton.SetResourceReference(BackgroundProperty, "DangerOnBrush");
        else BroadcastButton.ClearValue(BackgroundProperty);
    }

    // ── Тема: терминал всегда в теме приложения (без смешанных схем) ──

    private void ApplyTermTheme()
    {
        var light = QTermShared.ThemeManager.IsLight;
        _bridge?.SetTermTheme(light);
        Web.DefaultBackgroundColor = light ? System.Drawing.Color.White
            : System.Drawing.Color.FromArgb(0x1E, 0x1F, 0x22);
    }

    private void OnThemeChanged()
    {
        foreach (var t in _tabs) t.ThemeChanged();
        PaintBroadcastButton();
        ApplyTermTheme();
        if (ActiveTermTab() is { } id) RenderMonitor(_lastStats.GetValueOrDefault(id));
    }

    private static MenuItem ThemeMenu(string header, (string Mode, string Title)[] modes,
        Func<string> current, Action<string> set)
    {
        var m = new MenuItem { Header = header };
        foreach (var (mode, title) in modes)
        {
            var mi = new MenuItem { Header = title, IsChecked = current() == mode };
            var md = mode;
            mi.Click += (_, e) => { e.Handled = true; set(md); };
            m.Items.Add(mi);
        }
        return m;
    }

    private static string BuildTitle()
    {
        var ver = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "?";
        string stamp = "?";
        try
        {
            if (Environment.ProcessPath is { } exe)
                stamp = File.GetLastWriteTime(exe).ToString("dd.MM HH:mm:ss");
        }
        catch { }
        return $"QTerm {ver} · волна {WaveMarker.Wave} · бинарь {stamp}";
    }

    private void RefreshList()
    {
        var rows = _repo.VisibleSessions
            .Select(s => new NodeRow(s.Id, s.Name, $"{s.Username}@{s.Host}:{s.Port}"))
            .ToList();
        SessionList.ItemsSource = rows;
        CountLabel.Text = $"Нод: {rows.Count}";
    }

    // ── Ручная сортировка нод drag&drop (мак-канон): порядок локальный,
    // updatedAt не трогаем, merge синка сохраняет свой порядок на каждой стороне ──
    private Point _dragStart;
    private Guid? _dragId;

    private void SessionList_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(null);
        _dragId = (e.OriginalSource as DependencyObject) is { } d &&
            ItemsControl.ContainerFromElement(SessionList, d) is ListBoxItem { DataContext: NodeRow r }
            ? r.Id : null;
    }

    private void SessionList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (_dragId is not { } id || e.LeftButton != MouseButtonState.Pressed) return;
        var d = e.GetPosition(null) - _dragStart;
        if (Math.Abs(d.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(d.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragId = null;
        DragDrop.DoDragDrop(SessionList, new DataObject("qterm/node", id), DragDropEffects.Move);
    }

    private void SessionList_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData("qterm/node") is not Guid movedId) return;
        Guid? beforeId = (e.OriginalSource as DependencyObject) is { } d &&
            ItemsControl.ContainerFromElement(SessionList, d) is ListBoxItem { DataContext: NodeRow r }
            ? r.Id : null;
        if (beforeId == movedId) return;
        var list = _repo.Data.Sessions;
        var moved = list.FirstOrDefault(x => x.Id == movedId);
        if (moved is null) return;
        list.Remove(moved);
        var idx = beforeId is { } b ? list.FindIndex(x => x.Id == b) : -1;
        if (idx < 0) list.Add(moved); else list.Insert(idx, moved);
        _repo.Persist(sync: false);
        RefreshList();
    }

    private Session? SelectedNode() =>
        SessionList.SelectedItem is NodeRow row
            ? _repo.Data.Sessions.FirstOrDefault(s => s.Id == row.Id)
            : null;

    // ── Ноды: CRUD ──────────────────────────────────────────────────

    private void NodeAdd_Click(object sender, RoutedEventArgs e) =>
        SessionDialog.Edit(this, _repo, null);

    private void NodeEdit_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is { } s) SessionDialog.Edit(this, _repo, s);
    }

    private void NodeConnect_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is { } s && _bridge is not null) OpenSession(s);
    }

    private void NodeDisconnect_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } s) return;
        var ids = new List<Guid>();
        lock (_controllers)
            foreach (var (id, c) in _controllers)
                if (c.SessionRef.Id == s.Id) ids.Add(id);
        CloseTabs(ids);
    }

    private void NodeResetTrust_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } s) return;
        if (!s.Extra.ContainsKey("hostkey"))
        {
            MessageBox.Show(this, "У ноды нет сохранённого ключа хоста.", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (MessageBox.Show(this,
                $"Сбросить доверие «{s.Name}»? При следующем подключении ключ хоста будет принят заново (TOFU).",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        s.Extra.Remove("hostkey");
        s.UpdatedAt = QtJson.NowIso();
        _repo.Persist();
    }

    private void NodeForgetPassword_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } s) return;
        var pwKey = $"{s.Id.ToString("D").ToUpperInvariant()}.password";
        var legacyKey = $"{s.Id.ToString("D").ToUpperInvariant()}.privateKeyPassphrase";
        var had = (_repo.Data.Secrets?.Remove(pwKey) ?? false) |
                  (_repo.Data.Secrets?.Remove(legacyKey) ?? false);
        if (!had)
        {
            MessageBox.Show(this, "У ноды нет сохранённого пароля.", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        _repo.Persist();
        CountLabel.Text = $"Нод: {_repo.VisibleSessions.Count()} · пароль «{s.Name}» забыт";
    }

    private void NodeUnbindKeys_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } s) return;
        if (s.KeyID is null && s.PrivateKeyPath is null)
        {
            MessageBox.Show(this, "К ноде не привязаны ключи.", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (MessageBox.Show(this,
                $"Отвязать ключи от «{s.Name}» и перевести на пароль?\nСами ключи остаются в вейлте.",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Question,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        s.KeyID = null;
        s.PrivateKeyPath = null;
        s.AuthMethod = AuthMethod.password;
        s.UpdatedAt = QtJson.NowIso();
        _repo.Persist();
    }

    private void NodeDelete_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } s) return;
        if (MessageBox.Show(this,
                $"Удалить ноду «{s.Name}»?\nУдаление уедет на мак/андроид при синке.",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        // Канон: tombstone, не физическое удаление — иначе синк воскресит
        s.Deleted = true;
        s.UpdatedAt = QtJson.NowIso();
        _repo.Persist();
    }

    private void SessionList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (SelectedNode() is { } s && _bridge is not null) OpenSession(s);
    }

    // ── Открытие терминальной сессии ────────────────────────────────

    private void OpenSession(Session session)
    {
        var tabId = Guid.NewGuid();
        var vm = new TabVM { Id = tabId, Kind = TabKind.Term, Name = session.Name };
        _tabs.Add(vm);

        _bridge!.CreateTerm(tabId);
        ActivateTab(tabId);

        var ctl = new SshSessionController(
            tabId, session, _repo.KeyById(session.KeyID),
            key => _repo.Data.Secrets?.GetValueOrDefault(key))
        {
            AskPassword = prompt =>
                Dispatcher.Invoke(() => PasswordDialog.AskEx(this, prompt, withSave: true)),
            ConfirmHostKeyChange = (oldFp, newFp) => Dispatcher.Invoke(() =>
                MessageBox.Show(this,
                    $"КЛЮЧ ХОСТА «{session.Name}» ИЗМЕНИЛСЯ!\n\n" +
                    $"Был:   {oldFp}\nСтал:  {newFp}\n\n" +
                    "Это может быть перестановка сервера — или подмена.\nДоверять новому ключу?",
                    "QTerm — TOFU", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                    MessageBoxResult.No) == MessageBoxResult.Yes),
            SaveHostKey = b64 => Dispatcher.Invoke(() =>
            {
                var s = _repo.Data.Sessions.FirstOrDefault(x => x.Id == session.Id);
                if (s is null) return;
                s.Extra["hostkey"] = b64;
                s.UpdatedAt = QtJson.NowIso();
                _repo.Persist();
            }),
            SaveSecret = (key, value) => Dispatcher.Invoke(() =>
            {
                _repo.Data.Secrets ??= new();
                _repo.Data.Secrets[key] = value;
                _repo.Persist();
            }),
        };
        ctl.Output += data => _bridge!.Output(tabId, data);
        ctl.StateChanged += (state, reason) => RunOnUi(() =>
        {
            vm.DotBrush = state switch
            {
                SessState.Connected => Brushes.LimeGreen,
                SessState.Connecting => Brushes.Orange,
                _ => Brushes.IndianRed,
            };
            _tabStates[tabId] = state;
            if (_activeTab == tabId) UpdateReconnectBar();
            if (state == SessState.Connected)
            {
                StartMonitor(tabId, ctl);
                EnsureFiles(tabId, ctl); // файлы поднимаются С НОДОЙ (мак-канон)
            }
            else if (_monitors.Remove(tabId, out var deadMon)) deadMon.Dispose(); // не дёргать труп клиента
        });
        lock (_controllers) _controllers[tabId] = ctl;

        Task.Run(() => ctl.Connect(120, 30));
    }

    // ── Мониторинг сервера ──────────────────────────────────────────

    private void StartMonitor(Guid tabId, SshSessionController ctl)
    {
        if (_monitors.Remove(tabId, out var old)) old.Dispose(); // реконнект = свежий клиент
        var client = ctl.NetHandles().Client;
        if (client is null) return;
        var mon = new ServerMonitor(client);
        mon.Updated += stats => RunOnUi(() =>
        {
            _lastStats[tabId] = stats;
            if (_activeTab == tabId) RenderMonitor(stats);
        });
        _monitors[tabId] = mon;
    }

    private void RenderMonitor(MonitorStats? st)
    {
        if (st is null) { MonitorBar.Visibility = Visibility.Collapsed; return; }
        MonitorBar.Visibility = Visibility.Visible;
        MonitorPanel.Children.Clear();

        void Chip(string label, string value, int? hotPct = null, string? tooltip = null)
        {
            var fg = hotPct switch
            {
                >= 90 => Brushes.IndianRed,
                >= 80 => Brushes.Orange,
                _ => (Brush)FindResource("FgBrush"),
            };
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            if (label.Length > 0)
                sp.Children.Add(new TextBlock
                {
                    Text = label,
                    Foreground = (Brush)FindResource("DimBrush"),
                    Margin = new Thickness(0, 0, 5, 0),
                    FontSize = 11.5,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            sp.Children.Add(new TextBlock
            {
                Text = value,
                Foreground = fg,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var chip = new Border
            {
                Background = (Brush)FindResource("Panel2Brush"),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(8, 2, 8, 2),
                Margin = new Thickness(0, 2, 6, 2),
                Child = sp,
            };
            if (tooltip is { Length: > 0 }) chip.ToolTip = tooltip;
            MonitorPanel.Children.Add(chip);
        }

        // Спарклайн капнут (панель резиновая — чипы переносятся, за кадром ничего)
        var spark = st.Spark.Length > 12 ? st.Spark[^12..] : st.Spark;
        Chip("CPU", $"{spark} {st.CpuPct}%", st.CpuPct);
        var memPct = st.MemTotalMb > 0 ? (int)(100 * st.MemUsedMb / st.MemTotalMb) : 0;
        Chip("RAM", $"{st.MemUsedMb / 1024.0:0.0}/{st.MemTotalMb / 1024.0:0.0} ГБ", memPct);
        Chip("", $"↑{st.TxMbps:0.00} ↓{st.RxMbps:0.00} Mb/s");
        if (st.Uptime.Length > 0) Chip("up", st.Uptime);
        if (st.Users > 0) Chip("польз", st.Users.ToString(), tooltip: st.UsersDetail);
        foreach (var d in st.Disks) Chip(d.Mount, $"{d.Pct}%", d.Pct);
    }

    // ── Вкладки (терминалы + редакторы) ─────────────────────────────

    private void ActivateTab(Guid id)
    {
        var vm = _tabs.FirstOrDefault(t => t.Id == id);
        if (vm is null) return;
        _activeTab = id;
        foreach (var t in _tabs) t.IsActive = t.Id == id;
        Placeholder.Visibility = Visibility.Collapsed;

        Web.Visibility = Visibility.Visible;
        RenderMonitor(_lastStats.GetValueOrDefault(id));
        UpdateReconnectBar();
        _bridge?.Show(id);
        Web.Focus();
        _filesTab = id; // панель следует за активной нодой (мак-канон)
        if (FilesCol.Width.Value > 0) RenderFilesOrProgress();
    }

    // ── полоса вкладок: все вкладки на виду; одинаковые ноды — с номером ──

    /// <summary>Несколько вкладок одной ноды — «имя ·1», «имя ·2», чтобы различать с первого взгляда.</summary>
    private void RenumberTabs()
    {
        foreach (var g in _tabs.GroupBy(t => t.Name))
        {
            var i = 0;
            var many = g.Count() > 1;
            foreach (var t in g) t.Suffix = many ? $" ·{++i}" : "";
        }
    }

    private void FilesSplitter_DragCompleted(object sender, System.Windows.Controls.Primitives.DragCompletedEventArgs e) =>
        RememberFilesWidth();

    private void Tab_Click(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is Guid id) ActivateTab(id);
    }

    private void TabClose_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.Tag is Guid id) CloseTab(id);
    }

    /// <summary>false = отменено (редактор с правками).</summary>
    private bool CloseTab(Guid id)
    {
        var vm = _tabs.FirstOrDefault(t => t.Id == id);
        if (vm is null) return true;

        {
            SshSessionController? ctl;
            lock (_controllers) _controllers.Remove(id, out ctl);
            ctl?.Dispose();
            _bridge?.Close(id);
            if (_monitors.Remove(id, out var mon)) mon.Dispose();
            _lastStats.Remove(id);
            _tabStates.Remove(id);
            if (_files.Remove(id, out var fsvc)) fsvc.Dispose();
            if (_filesTab == id) { _filesTab = null; HideFiles(); }
        }
        _tabs.Remove(vm);
        if (_activeTab == id)
        {
            _activeTab = null;
            if (_tabs.Count > 0) ActivateTab(_tabs[^1].Id);
            else
            {
                Placeholder.Visibility = Visibility.Visible;
                Web.Visibility = Visibility.Visible;
                MonitorBar.Visibility = Visibility.Collapsed;
            }
        }
        return true;
    }

    private void CloseTabs(IEnumerable<Guid> ids)
    {
        foreach (var id in ids.ToList()) CloseTab(id);
    }

    private void Tab_RightClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.Tag is not Guid id) return;
        var vm = _tabs.FirstOrDefault(t => t.Id == id);
        if (vm is null) return;

        var menu = new ContextMenu { PlacementTarget = sender as UIElement };
        if (vm.Kind == TabKind.Term)
        {
            var mi = new MenuItem { Header = "Переподключить" };
            mi.Click += (_, _) =>
            {
                SshSessionController? c;
                lock (_controllers) _controllers.TryGetValue(id, out c);
                if (c is not null) Task.Run(c.Reconnect);
            };
            menu.Items.Add(mi);
            var dev = new MenuItem { Header = "DevTools (диагностика)" };
            dev.Click += (_, _) => Web.CoreWebView2?.OpenDevToolsWindow();
            menu.Items.Add(dev);
            menu.Items.Add(new Separator());
        }
        var close = new MenuItem { Header = "Закрыть" };
        close.Click += (_, _) => CloseTab(id);
        menu.Items.Add(close);
        var others = new MenuItem { Header = "Закрыть остальные" };
        others.Click += (_, _) => CloseTabs(_tabs.Where(t => t.Id != id).Select(t => t.Id));
        menu.Items.Add(others);
        var all = new MenuItem { Header = "Закрыть все" };
        all.Click += (_, _) => CloseTabs(_tabs.Select(t => t.Id));
        menu.Items.Add(all);
        menu.IsOpen = true;
    }

    private void UpdateReconnectBar()
    {
        var show = ActiveTermTab() is { } id &&
            _tabStates.GetValueOrDefault(id, SessState.Connecting)
                is SessState.Disconnected or SessState.Failed;
        ReconnectBar.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ReconnectNow_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveTermTab() is not { } id) return;
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(id, out c);
        if (c is not null) Task.Run(c.Reconnect);
    }

    private void ClearTerm_Click(object sender, RoutedEventArgs e)
    {
        // Очистка активного терминала: экран + скроллбек (мак-канон)
        var target = _activeTab is { } a &&
            _tabs.FirstOrDefault(t => t.Id == a) is { Kind: TabKind.Term }
            ? a : _filesTab;
        if (target is { } id) _bridge?.Clear(id);
    }

    // ── Ключи / прочее ──────────────────────────────────────────────

    private XuiWindow? _xuiWin;

    /// <summary>Ноды 3x-ui: одно окно, без Owner (owned-окно всегда висело бы над QTerm).</summary>
    private void XuiButton_Click(object sender, RoutedEventArgs e) => ShowXui();

    private void ShowXui()
    {
        if (_xuiWin is null || !_xuiWin.IsLoaded)
        {
            _xuiWin = new XuiWindow(_repo) { RunInTerminal = RunInSessionAsync };
            _xuiWin.Closed += (_, _) => _xuiWin = null;
            Closed += (_, _) => _xuiWin?.Close();
            _xuiWin.Show();
        }
        if (_xuiWin.WindowState == WindowState.Minimized) _xuiWin.WindowState = WindowState.Normal;
        _xuiWin.Activate();
    }

    /// <summary>Выделил в терминале итог установщика (выделение = копия в буфер) → хоткей →
    /// «новая или переустановка», вход, токен, сохранение в вейлт → окно «Ноды 3x-ui» на нужной вкладке.</summary>
    private void AddNodeFromSelection()
    {
        var text = "";
        try { text = Clipboard.GetText(); } catch { /* буфер занят — откроем пустую форму */ }
        var dlg = new NodeAddWindow(new XuiStore(_repo), text) { Owner = this };
        dlg.ShowDialog();
        if (dlg.Saved.Count == 0) return;
        // пароли из итога не должны висеть в буфере
        try
        {
            var clip = Clipboard.GetText();
            if (dlg.Passwords.Any(pw => clip.Contains(pw, StringComparison.Ordinal))) Clipboard.Clear();
        }
        catch { }
        ShowXui();
        _xuiWin?.AfterNodeAdded(dlg.Saved, dlg.ConnectId);
    }

    private void MoreButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = MoreButton };
        var imp = new MenuItem { Header = "Импорт .qtvault…" };
        imp.Click += (_, _) => ImportButton_Click(sender, e);
        menu.Items.Add(imp);
        var keys = new MenuItem { Header = "Ключи…" };
        keys.Click += (_, _) => new KeysWindow(_repo) { Owner = this }.ShowDialog();
        menu.Items.Add(keys);
        menu.Items.Add(new Separator());
        var hello = new MenuItem
        {
            Header = "Требовать Windows Hello при запуске",
            IsCheckable = true,
            IsChecked = Security.AppSettings.Load().HelloRequired,
        };
        hello.Click += async (_, _) =>
        {
            try
            {
                if (hello.IsChecked) await Security.HelloGate.EnableAsync();
                else Security.HelloGate.Disable();
            }
            catch (Exception ex)
            {
                hello.IsChecked = false;
                MessageBox.Show(this, "Windows Hello: " + ex.Message, "QTerm",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        menu.Items.Add(hello);
        var ed = new MenuItem { Header = "QEditor (скрапбук)…", InputGestureText = KeyText("qeditor") };
        ed.Click += (_, _) => _ = OpenScrapbookAsync();
        menu.Items.Add(ed);
        var xui = new MenuItem { Header = "Ноды 3x-ui…", InputGestureText = KeyText("xui") };
        xui.Click += (_, _) => ShowXui();
        menu.Items.Add(xui);
        var nodeAdd = new MenuItem { Header = "Нода из выделения (3x-ui / AWG)…", InputGestureText = KeyText("nodeadd") };
        nodeAdd.Click += (_, _) => Dispatcher.InvokeAsync(AddNodeFromSelection);
        menu.Items.Add(nodeAdd);
        menu.Items.Add(ThemeMenu("Тема", QTermShared.ThemeManager.Modes,
            () => QTermShared.ThemeManager.Mode,
            mode =>
            {
                var st = Security.AppSettings.Load();
                st.Theme = mode;
                st.Save();
                QTermShared.ThemeManager.Apply(mode); // → Changed → OnThemeChanged
            }));
        menu.Items.Add(new Separator());
        var hk = new MenuItem { Header = "Горячие клавиши…", InputGestureText = KeyText("hotkeys") };
        hk.Click += (_, _) => Dispatcher.InvokeAsync(ShowHotkeys);
        menu.Items.Add(hk);
        var font = new MenuItem { Header = "Шрифт и терминал…" };
        font.Click += (_, _) => new FontDialog(
            sz => _bridge?.SetTermFontSize(sz),
            sb => _bridge?.SetScrollback(sb)) { Owner = this }.ShowDialog();
        menu.Items.Add(font);
        var editor = new MenuItem { Header = "Внешний редактор…" };
        editor.Click += (_, _) =>
        {
            var st = Security.AppSettings.Load();
            var dlg = new OpenFileDialog
            {
                Title = "Выбери exe редактора (Отмена = системная ассоциация)",
                Filter = "Программы (*.exe)|*.exe",
            };
            st.ExternalEditor = dlg.ShowDialog(this) == true ? dlg.FileName : null;
            st.Save();
            CountLabel.Text = st.ExternalEditor is null
                ? "Внешний редактор: системная ассоциация"
                : $"Внешний редактор: {Path.GetFileName(st.ExternalEditor)}";
        };
        menu.Items.Add(editor);
        var log = new MenuItem { Header = "Журнал команд…", InputGestureText = KeyText("journal") };
        log.Click += (_, _) => new CmdLogWindow(_repo) { Owner = this }.ShowDialog();
        menu.Items.Add(log);
        menu.Items.Add(new Separator());
        var about = new MenuItem { Header = "О приложении" };
        about.Click += (_, _) => new AboutWindow { Owner = this }.ShowDialog();
        menu.Items.Add(about);
        menu.IsOpen = true;
    }

    // ── Команды (сниппеты из вейлта) ────────────────────────────────

    private void SyncButton_Click(object sender, RoutedEventArgs e)
    {
        if (_sync is null) return;
        new SyncWindow(_sync) { Owner = this }.ShowDialog();
    }

    private void SnippetsButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = SnippetsButton };
        var snips = _repo.Data.Snippets?
            .Where(s => s.Deleted != true)
            .OrderBy(s => s.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (snips is { Count: > 0 })
        {
            foreach (var sn in snips)
            {
                var mi = new MenuItem { Header = sn.Title, ToolTip = sn.Command };
                var cmd = sn.Command;
                mi.Click += (_, _) => SendToActive(cmd.TrimEnd('\n') + "\n");
                menu.Items.Add(mi);
            }
            menu.Items.Add(new Separator());
        }
        var log = new MenuItem { Header = "Журнал команд…" };
        log.Click += (_, _) => new CmdLogWindow(_repo) { Owner = this }.ShowDialog();
        menu.Items.Add(log);
        menu.Items.Add(new Separator());
        var about = new MenuItem { Header = "О приложении" };
        about.Click += (_, _) => new AboutWindow { Owner = this }.ShowDialog();
        menu.Items.Add(about);
        menu.IsOpen = true;
    }

    // ── Команды Git ──

    // Кнопка — редактор (добавить/править), хоткей — палитра быстрого вызова
    private void GitButton_Click(object sender, RoutedEventArgs e) => ShowGitCommands();

    private void GitButton_RightClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var menu = new ContextMenu { PlacementTarget = GitButton };
        var quick = new MenuItem { Header = "Быстрый вызов", InputGestureText = KeyText("git") };
        quick.Click += (s, a) => Dispatcher.InvokeAsync(ShowGitQuick);
        menu.Items.Add(quick);
        var edit = new MenuItem { Header = "Редактор команд…", InputGestureText = KeyText("gitedit") };
        edit.Click += (s, a) => Dispatcher.InvokeAsync(() => ShowGitCommands());
        menu.Items.Add(edit);
        var add = new MenuItem { Header = "Новая команда…" };
        add.Click += (s, a) => Dispatcher.InvokeAsync(() => ShowGitCommands(null, true));
        menu.Items.Add(add);
        menu.IsOpen = true;
    }

    private bool _gitOpen;

    /// <summary>Быстрый вызов: палитра над терминалом, Enter — в терминал.</summary>
    private void ShowGitQuick()
    {
        if (_gitOpen) return;
        _gitOpen = true;
        GitQuickWindow.QuickAction act;
        string? text;
        Guid? entry;
        try
        {
            var w = new GitQuickWindow(_repo, _keys.GetValueOrDefault("git")) { Owner = this };
            PlaceOverTerminal(w);
            if (w.ShowDialog() != true) { FocusTerminal(); return; }
            act = w.Chosen;
            text = w.Text;
            entry = w.EntryId;
        }
        finally { _gitOpen = false; }

        switch (act)
        {
            case GitQuickWindow.QuickAction.Run:
            case GitQuickWindow.QuickAction.Insert:
                if (text is not null) DeliverCommand(text, act == GitQuickWindow.QuickAction.Run);
                break;
            case GitQuickWindow.QuickAction.Edit:
                Dispatcher.InvokeAsync(() => ShowGitCommands(entry));
                break;
            case GitQuickWindow.QuickAction.New:
                Dispatcher.InvokeAsync(() => ShowGitCommands(null, true));
                break;
        }
    }

    /// <summary>Палитра — по центру над областью терминала, у верхнего края (как в VS Code).
    /// Точка — в пикселях устройства (WindowFit): на мониторах с разным масштабом DIP-координаты врут.</summary>
    private void PlaceOverTerminal(Window w)
    {
        try
        {
            FrameworkElement anchor = Web.IsVisible ? Web : this;
            var tl = anchor.PointToScreen(new Point(0, 0));
            var br = anchor.PointToScreen(new Point(anchor.ActualWidth, anchor.ActualHeight));
            var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            w.Width = Math.Min(w.Width, Math.Max(420, (br.X - tl.X) / scale));
            QTermShared.WindowFit.PlaceOver(w, new Rect(tl, br), 24);
        }
        catch { w.WindowStartupLocation = WindowStartupLocation.CenterOwner; }
    }

    private void FocusTerminal()
    {
        if (_activeTab is { } a && _tabs.FirstOrDefault(t => t.Id == a) is { Kind: TabKind.Term })
            _bridge?.Show(a);
        Web.Focus();
    }

    /// <summary>Команду — в SSH-терминал сессии (для «Нод 3x-ui»: установка/откат версии панели):
    /// есть подключённая вкладка этой ноды — в неё, нет — открыть; дождаться подключения и шелла.</summary>
    public async Task<bool> RunInSessionAsync(Guid sessionId, string command)
    {
        var s = _repo.Data.Sessions.FirstOrDefault(x => x.Id == sessionId && x.Deleted != true);
        if (s is null) return false;
        Guid tab = Guid.Empty;
        lock (_controllers)
            foreach (var (id, c) in _controllers)
                if (c.SessionRef.Id == sessionId && _tabStates.GetValueOrDefault(id) == SessState.Connected) { tab = id; break; }
        var fresh = tab == Guid.Empty;
        if (fresh)
        {
            OpenSession(s);
            if (_activeTab is not { } a) return false;
            tab = a;
        }
        else ActivateTab(tab);
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        for (int i = 0; i < 120 && _tabStates.GetValueOrDefault(tab) != SessState.Connected; i++) await Task.Delay(500);
        if (_tabStates.GetValueOrDefault(tab) != SessState.Connected) return false;
        // SSH.NET глотает ранний ввод шелла — даём ему подняться
        if (fresh) await Task.Delay(2000);
        SshSessionController? ctl;
        lock (_controllers) _controllers.TryGetValue(tab, out ctl);
        if (ctl is null) return false;
        ctl.Write(System.Text.Encoding.UTF8.GetBytes(command + "\n"));
        FocusTerminal();
        return true;
    }

    /// <summary>Команду — в активный терминал (или во все при «Во все»); нет терминала — в буфер.</summary>
    private void DeliverCommand(string text, bool execute)
    {
        if (!SendToActive(execute ? text + "\n" : text))
        {
            try { Clipboard.SetText(text); } catch { }
            MessageBox.Show(this, "Нет открытого терминала — команда скопирована в буфер.",
                "QTerm", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        FocusTerminal();
    }

    /// <summary>Полный редактор команд Git.</summary>
    private void ShowGitCommands(Guid? select = null, bool startNew = false)
    {
        if (_gitOpen) return;
        _gitOpen = true;
        string? text;
        bool exec;
        try
        {
            var w = new GitCmdsWindow(_repo, select, startNew) { Owner = this };
            if (w.ShowDialog() != true || w.ResultText is null) { FocusTerminal(); return; }
            text = w.ResultText;
            exec = w.ResultExecute;
        }
        finally { _gitOpen = false; }
        DeliverCommand(text, exec);
    }

    private bool SendToActive(string text)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(text);
        // «Во все» включён → сниппет летит на все ноды ЦЕЛИКОМ (безопасный
        // способ выполнить одинаковое везде — без историй и автодополнений)
        if (_broadcast)
        {
            List<SshSessionController> all;
            lock (_controllers) all = _controllers.Values.ToList();
            foreach (var ctl in all) ctl.Write(bytes);
            return all.Count > 0;
        }
        var target = _activeTab is { } a &&
            _tabs.FirstOrDefault(t => t.Id == a) is { Kind: TabKind.Term }
            ? a : _filesTab;
        if (target is not { } id) return false;
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(id, out c);
        if (c is null) return false;
        c.Write(bytes);
        return true;
    }

    // ── Импорт ──────────────────────────────────────────────────────

    private void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Filter = "Вейлт QTerm (*.qtvault)|*.qtvault|Все файлы (*.*)|*.*",
            Title = "Импорт вейлта",
        };
        if (dlg.ShowDialog(this) != true) return;

        byte[] blob;
        try { blob = File.ReadAllBytes(dlg.FileName); }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "QTerm", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        var pw = PasswordDialog.Ask(this, Path.GetFileName(dlg.FileName));
        if (pw is null) return;

        SessionVault imported;
        try { imported = QtVaultFile.Decrypt(blob, pw); }
        catch (QtVaultFile.BadPasswordOrCorruptException)
        {
            MessageBox.Show(this, "Неверный пароль или повреждённый файл.",
                "QTerm", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Импорт не удался:\n" + ex.Message,
                "QTerm", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        var stats = _repo.MergeImport(imported);
        MessageBox.Show(this, stats.ToString(), "Импорт выполнен",
            MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
