using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Sona.Core;

namespace Sona.Windows;

internal sealed class AssistantSettingsWindow : Window
{
    private readonly ComboBox providers = new(), models = new(), efforts = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12) };
    private readonly Button save = new() { Content = "Save Assistant choices", IsEnabled = false, Padding = new Thickness(12, 8, 12, 8) };
    private readonly CancellationTokenSource cancellation = new();
    private AssistantOptions saved = new();
    public AssistantSettingsWindow(string path, Func<CancellationToken, Task<AssistantCatalog?>> catalog)
    {
        Title = "Sona Assistant choices"; Width = 500; Height = 470; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var content = new StackPanel { Margin = new Thickness(25) }; Content = content;
        content.Children.Add(new TextBlock { Text = "Your saved Option connection", FontSize = 24, FontWeight = FontWeights.SemiBold });
        content.Children.Add(new TextBlock { Text = "These choices apply to selected edits and foreground-window questions. Normal dictation keeps its fixed economical model. No model request is made here.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12), Foreground = Brushes.DimGray });
        foreach (var item in new[] { ("Provider", providers), ("Model", models), ("Effort", efforts) }) { content.Children.Add(new TextBlock { Text = item.Item1, Margin = new Thickness(0, 9, 0, 4) }); content.Children.Add(item.Item2); }
        content.Children.Add(status); content.Children.Add(save);
        providers.SelectionChanged += (_, _) => LoadModels(); models.SelectionChanged += (_, _) => LoadEfforts(); efforts.SelectionChanged += (_, _) => Availability();
        Loaded += async (_, _) =>
        {
            status.Text = "Reading the provider catalog…";
            try
            {
                var document = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? throw new InvalidDataException() : new JsonObject();
                saved = AssistantOptions.Read(document["assistant"]);
                var result = await catalog(cancellation.Token);
                if (result == null || cancellation.IsCancellationRequested) { status.Text = "The catalog is unavailable. Existing choices have been retained."; return; }
                providers.ItemsSource = result.Providers;
                providers.SelectedItem = result.Providers.FirstOrDefault(p => p.Id == saved.Provider) ?? result.Providers.FirstOrDefault(p => p.Id == result.Selected.Provider) ?? result.Providers.FirstOrDefault(p => p.Available);
                if (providers.SelectedItem is AssistantProvider selected)
                {
                    models.SelectedItem = selected.Models.FirstOrDefault(m => m.Id == saved.Model) ?? selected.Models.FirstOrDefault(m => m.Id == result.Selected.Model) ?? models.SelectedItem;
                    efforts.SelectedItem = efforts.Items.Cast<string>().FirstOrDefault(e => e == saved.Effort) ?? efforts.Items.Cast<string>().FirstOrDefault(e => e == result.Selected.Effort) ?? efforts.SelectedItem;
                }
                Availability();
            }
            catch { status.Text = "Assistant configuration or catalog could not be read. Nothing has been saved."; }
        };
        save.Click += (_, _) =>
        {
            if (providers.SelectedItem is not AssistantProvider provider || models.SelectedItem is not AssistantModel model || efforts.SelectedItem is not string effort) return;
            try
            {
                var document = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new InvalidDataException() : new JsonObject();
                document["assistant"] = new AssistantOptions(provider.Id, model.Id, effort, saved.TimeoutMs).ToJson();
                FeatureConfig.CommitDocuments((path, document)); Close();
            }
            catch { status.Text = "Saving failed. Existing settings were retained."; }
        };
        Closed += (_, _) => { cancellation.Cancel(); cancellation.Dispose(); };
    }
    private void LoadModels()
    {
        models.ItemsSource = (providers.SelectedItem as AssistantProvider)?.Models;
        models.SelectedIndex = models.Items.Count > 0 ? 0 : -1;
    }
    private void LoadEfforts()
    {
        var model = models.SelectedItem as AssistantModel; efforts.ItemsSource = model?.Efforts.Length > 0 ? model.Efforts : new[] { "default" }; efforts.IsEnabled = model?.Efforts.Length > 0;
        efforts.SelectedItem = model?.DefaultEffort;
        if (efforts.SelectedIndex < 0 && efforts.Items.Count > 0) efforts.SelectedIndex = 0;
        Availability();
    }
    private void Availability()
    {
        var provider = providers.SelectedItem as AssistantProvider; var model = models.SelectedItem as AssistantModel;
        save.IsEnabled = provider != null && model != null && efforts.SelectedItem is string;
        status.Text = provider == null ? "No provider is available." : !provider.Available ? "Connection unavailable: " + (provider.Reason ?? "authentication or runtime missing") + ". You may save it for later. Sona will not switch accounts." : model?.Vision == true ? "Supports foreground-window questions. Account usage and provider retention policies apply." : "Text edits only. This model cannot receive window images; screen questions will fail safely.";
    }
}
