using System.ComponentModel;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using QTermWin.Files;

namespace QTermWin.UI;

/// <summary>
/// Простой редактор удалённого файла поверх файлового бекенда сессии.
/// Line endings: файл без CRLF сохраняется без CRLF, что бы ни навводил
/// WPF TextBox (Enter вставляет \r\n — конфиги на роутере это ломает).
/// </summary>
public partial class EditorWindow : Window
{
    private readonly FileService _svc;
    private readonly string _remotePath;
    private readonly bool _hadCrLf;
    private bool _dirty;
    private bool _saving;

    public EditorWindow(FileService svc, string remotePath, string text)
    {
        InitializeComponent();
        _svc = svc;
        _remotePath = remotePath;
        _hadCrLf = text.Contains("\r\n");
        Box.Text = text;
        _dirty = false;
        UpdateTitle();
        Closing += OnClosing;
    }

    private void UpdateTitle() =>
        Title = (_dirty ? "• " : "") + _remotePath + " — QTerm";

    private void Box_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_dirty) return;
        _dirty = true;
        UpdateTitle();
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e) => Save();
    private void Save_Executed(object sender, System.Windows.Input.ExecutedRoutedEventArgs e) => Save();

    private void Save()
    {
        if (_saving) return;
        _saving = true;
        Status.Text = "Сохранение…";
        var text = Box.Text;
        if (!_hadCrLf) text = text.Replace("\r\n", "\n");
        var data = Encoding.UTF8.GetBytes(text);
        Task.Run(() =>
        {
            try
            {
                _svc.UploadL(_remotePath, data);
                Dispatcher.Invoke(() =>
                {
                    _saving = false;
                    _dirty = false;
                    UpdateTitle();
                    Status.Text = $"Сохранено {DateTime.Now:HH:mm:ss} ({data.Length} байт)";
                });
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() =>
                {
                    _saving = false;
                    Status.Text = "Ошибка: " + ex.Message;
                });
            }
        });
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!_dirty) return;
        if (MessageBox.Show(this, "Есть несохранённые правки. Выйти без сохранения?",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) != MessageBoxResult.Yes)
            e.Cancel = true;
    }
}
