# DarkZombie v1.0.0 - KushZombie Software
# Standalone Windows PowerShell 5.1 + WPF app, no third-party dependencies.
# Original implementation. Does not modify or redistribute Dimmer.exe.

param([switch]$Windowed)

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.4'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigDir = Join-Path $env:LOCALAPPDATA 'DarkZombie'
$script:ConfigPath = Join-Path $script:ConfigDir 'settings.json'
$script:LogPath = Join-Path $script:ConfigDir 'error.log'
$script:Levels = @{}
$script:Favorite = @{}
$script:Overlays = @{}
$script:Cards = @{}
$script:Screens = @()
$script:ProgrammaticUpdate = $false
$script:Exiting = $false
$script:IsFullscreen = $false
$script:SavedWindow = $null
$script:UiReady = $false
$script:Window = $null
$script:Tray = $null
$script:SaveTimer = $null
$script:SingletonMutex = $null
$script:ActivationSignal = $null
$script:ActivationTimer = $null

function Write-DZLog([string]$Message) {
    try {
        if (!(Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) |
            Out-File -LiteralPath $script:LogPath -Append -Encoding utf8
    } catch { }
}

function Load-DZSettings {
    if (!(Test-Path -LiteralPath $script:ConfigPath)) { return }
    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($null -ne $config.levels) {
            foreach ($p in $config.levels.PSObject.Properties) {
                $script:Levels[$p.Name] = [Math]::Max(0, [Math]::Min(85, [int]$p.Value))
            }
        }
        if ($null -ne $config.favorite) {
            foreach ($p in $config.favorite.PSObject.Properties) {
                $script:Favorite[$p.Name] = [Math]::Max(0, [Math]::Min(85, [int]$p.Value))
            }
        }
    } catch {
        Write-DZLog ('Could not read prior settings; defaults used: ' + $_.Exception.Message)
    }
}

function Save-DZSettings {
    try {
        if (!(Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $settings = [ordered]@{
            schema = 1
            version = $script:Version
            levels = $script:Levels
            favorite = $script:Favorite
            saved_at = (Get-Date).ToString('o')
        }
        $json = $settings | ConvertTo-Json -Depth 6
        $tempPath = $script:ConfigPath + '.tmp'
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
    } catch {
        Write-DZLog ('Could not save settings: ' + $_.Exception.Message)
    }
}

function Schedule-DZSave {
    if ($null -ne $script:SaveTimer) {
        $script:SaveTimer.Stop()
        $script:SaveTimer.Start()
    }
}

try {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'DarkZombie must run in STA mode. Use Launch_DarkZombie.cmd.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Give this otherwise generic PowerShell-hosted WPF window its own taskbar group.
    # Must happen before the window is created. Failure is non-fatal for dimming.
    try {
        $taskbarIdentityCode = @'
using System;
using System.Runtime.InteropServices;
public static class DarkZombieTaskbarIdentity {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
        Add-Type -TypeDefinition $taskbarIdentityCode -ErrorAction Stop
        $appIdResult = [DarkZombieTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('KushZombieSoftware.DarkZombie')
        if ($appIdResult -ne 0) {
            Write-DZLog ('AppUserModelID returned HRESULT ' + $appIdResult)
        }
    } catch {
        Write-DZLog ('Nonfatal taskbar identity issue: ' + $_.Exception.Message)
    }

    # Prevent duplicate overlays; launching again opens the running UI.
    $createdNew = $false
    $script:SingletonMutex = [System.Threading.Mutex]::new($true, 'Local\KushZombie_DarkZombie_SingleInstance', [ref]$createdNew)
    $script:ActivationSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\KushZombie_DarkZombie_Activate')
    if (!$createdNew) {
        [void]$script:ActivationSignal.Set()
        [System.Windows.Forms.MessageBox]::Show(
            'DarkZombie is already running, possibly hidden in the system tray. Exit the OLD instance using its tray icon, then open this version again. No second dimming instance was started.',
            'DarkZombie - already running',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $script:ActivationSignal.Dispose()
        $script:SingletonMutex.Dispose()
        exit 0
    }

    # A borderless always-on-top form on every display, with click-through
    # and no-focus extended styles. This is overlay dimming, not DDC/CI.
    $OverlaySource = @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace DarkZombie {
    public sealed class ScreenOverlay : Form {
        public ScreenOverlay(Rectangle bounds) {
            StartPosition = FormStartPosition.Manual;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            BackColor = Color.Black;
            TopMost = true;
            Bounds = bounds;
            Opacity = 0.0;
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                // WS_EX_TRANSPARENT + WS_EX_TOOLWINDOW + WS_EX_NOACTIVATE
                cp.ExStyle |= 0x20 | 0x80 | 0x08000000;
                return cp;
            }
        }
        protected override void WndProc(ref Message m) {
            // Transparent to pointer input, including on the host monitor.
            if (m.Msg == 0x0084) { m.Result = new IntPtr(-1); return; }
            base.WndProc(ref m);
        }
        public void SetLevel(int percentage) {
            if (IsDisposed) return;
            percentage = Math.Max(0, Math.Min(85, percentage));
            if (percentage == 0) { if (Visible) Hide(); return; }
            Opacity = percentage / 100.0;
            if (!Visible) Show();
        }
    }
}
'@
    Add-Type -TypeDefinition $OverlaySource -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    Load-DZSettings

    $WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DarkZombie | KushZombie Software"
        Background="#060708" Foreground="#F5F7FA"
        FontFamily="Segoe UI" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="False" MinWidth="1050" MinHeight="600"
        Width="1260" Height="810" WindowStartupLocation="CenterScreen"
        ShowInTaskbar="True" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
    <!-- Premium dark button with soft glow -->
    <Style x:Key="DarkButton" TargetType="Button">
      <Setter Property="Foreground" Value="#EDE9FE"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Background" Value="#12141A"/>
      <Setter Property="BorderBrush" Value="#5B2BC7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="16,11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="frame" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="12" SnapsToDevicePixels="True">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#161922" Offset="0"/>
                  <GradientStop Color="#0F1116" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect>
                <DropShadowEffect Color="#5B2BC7" BlurRadius="0" ShadowDepth="0" Opacity="0"/>
              </Border.Effect>
              <ContentPresenter Content="{TemplateBinding Content}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="frame" Property="BorderBrush" Value="#3DFF9A"/>
                <Setter TargetName="frame" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#1A1F28" Offset="0"/>
                      <GradientStop Color="#12151C" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="frame" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#3DFF9A" BlurRadius="12" ShadowDepth="0" Opacity="0.35"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="frame" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#0E1116" Offset="0"/>
                      <GradientStop Color="#0A0C10" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="frame" Property="BorderBrush" Value="#5CFFAB"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Premium accent / action button -->
    <Style x:Key="GreenButton" TargetType="Button" BasedOn="{StaticResource DarkButton}">
      <Setter Property="Foreground" Value="#B8FF6A"/>
      <Setter Property="BorderBrush" Value="#3DFF9A"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="frame" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1.5" CornerRadius="12" SnapsToDevicePixels="True">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#0F1A14" Offset="0"/>
                  <GradientStop Color="#0A120E" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect>
                <DropShadowEffect Color="#3DFF9A" BlurRadius="8" ShadowDepth="0" Opacity="0.22"/>
              </Border.Effect>
              <ContentPresenter Content="{TemplateBinding Content}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#E8FFF0"/>
                <Setter TargetName="frame" Property="BorderBrush" Value="#5CFFAB"/>
                <Setter TargetName="frame" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#3DFF9A" BlurRadius="16" ShadowDepth="0" Opacity="0.45"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="frame" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#13241A" Offset="0"/>
                      <GradientStop Color="#0D1A12" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter Property="Foreground" Value="#E8D5FF"/>
                <Setter TargetName="frame" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#0A140F" Offset="0"/>
                      <GradientStop Color="#07100B" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Premium neon slider -->
    <Style x:Key="NeonSlider" TargetType="Slider">
      <Setter Property="Height" Value="48"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="85"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="TickFrequency" Value="1"/>
      <Setter Property="AutoToolTipPlacement" Value="TopLeft"/>
      <Setter Property="AutoToolTipPrecision" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="48" Margin="0">
              <!-- Track background -->
              <Border Height="10" VerticalAlignment="Center" CornerRadius="5" Margin="4,0">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#1A1E28" Offset="0"/>
                    <GradientStop Color="#12151C" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <Track x:Name="PART_Track" Height="14" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border CornerRadius="5" Margin="0,2">
                          <Border.Background>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                              <GradientStop Color="#6D28D9" Offset="0"/>
                              <GradientStop Color="#8B5CF6" Offset="1"/>
                            </LinearGradientBrush>
                          </Border.Background>
                          <Border.Effect>
                            <DropShadowEffect Color="#7C3AED" BlurRadius="8" ShadowDepth="0" Opacity="0.4"/>
                          </Border.Effect>
                        </Border>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="28" Height="28">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid>
                          <Ellipse Width="28" Height="28" Fill="#0D1016" Stroke="#3DFF9A" StrokeThickness="3.5">
                            <Ellipse.Effect>
                              <DropShadowEffect Color="#3DFF9A" BlurRadius="14" ShadowDepth="0" Opacity="0.55"/>
                            </Ellipse.Effect>
                          </Ellipse>
                          <Ellipse Width="10" Height="10" Fill="#B8FF6A" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.9"/>
                        </Grid>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Purple-themed scrollbar (replaces default light/white system scrollbar) -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumb" Background="#5E2ACD" CornerRadius="6" Margin="2,1"
                                BorderBrush="#7C3CFF" BorderThickness="1">
                          <Border.Effect>
                            <DropShadowEffect Color="#7C3CFF" BlurRadius="6" ShadowDepth="0" Opacity="0.45"/>
                          </Border.Effect>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="thumb" Property="Background" Value="#7C3CFF"/>
                            <Setter TargetName="thumb" Property="BorderBrush" Value="#A78BFA"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="thumb" Property="Background" Value="#9B5CFF"/>
                            <Setter TargetName="thumb" Property="BorderBrush" Value="#C4B5FD"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageLeftCommand" Focusable="False">
                        <RepeatButton.Template>
                          <ControlTemplate TargetType="RepeatButton">
                            <Border Background="Transparent"/>
                          </ControlTemplate>
                        </RepeatButton.Template>
                      </RepeatButton>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb>
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border x:Name="thumb" Background="#5E2ACD" CornerRadius="6" Margin="1,2"
                                    BorderBrush="#7C3CFF" BorderThickness="1">
                              <Border.Effect>
                                <DropShadowEffect Color="#7C3CFF" BlurRadius="6" ShadowDepth="0" Opacity="0.45"/>
                              </Border.Effect>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="thumb" Property="Background" Value="#7C3CFF"/>
                                <Setter TargetName="thumb" Property="BorderBrush" Value="#A78BFA"/>
                              </Trigger>
                              <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="thumb" Property="Background" Value="#9B5CFF"/>
                                <Setter TargetName="thumb" Property="BorderBrush" Value="#C4B5FD"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageRightCommand" Focusable="False">
                        <RepeatButton.Template>
                          <ControlTemplate TargetType="RepeatButton">
                            <Border Background="Transparent"/>
                          </ControlTemplate>
                        </RepeatButton.Template>
                      </RepeatButton>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid Background="#050607">
    <Grid.RowDefinitions>
      <RowDefinition Height="88"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="52"/>
    </Grid.RowDefinitions>
    <!-- Premium header -->
    <Border Grid.Row="0" BorderBrush="#2E1A4A" BorderThickness="0,0,0,1">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#0C0E14" Offset="0"/>
          <GradientStop Color="#080A0E" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Grid Margin="26,0,24,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" x:Name="TitleDragArea" Cursor="SizeAll">
          <Border Width="50" Height="50" BorderBrush="#8B5CF6" BorderThickness="2" CornerRadius="14" Margin="0,0,14,0">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#1A1228" Offset="0"/>
                <GradientStop Color="#0D1018" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
              <DropShadowEffect Color="#7C3AED" BlurRadius="12" ShadowDepth="0" Opacity="0.45"/>
            </Border.Effect>
            <Grid>
              <TextBlock Text="DZ" FontSize="21" FontWeight="Black" Foreground="#B8FF6A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="DARK" Foreground="#C4B5FD" FontWeight="Black" FontSize="25"/>
              <TextBlock Text="ZOMBIE" Foreground="#B8FF6A" FontWeight="Black" FontSize="25"/>
            </StackPanel>
            <TextBlock Text="KUSHZOMBIE SOFTWARE  ·  DISPLAY CONTROL" Foreground="#6B7280" FontSize="10" FontWeight="SemiBold" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <Border Grid.Column="2" CornerRadius="20" Padding="16,9" BorderBrush="#3DFF9A" BorderThickness="1" Margin="0,0,14,0" VerticalAlignment="Center">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#0F1A14" Offset="0"/>
              <GradientStop Color="#0A120E" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <Border.Effect>
            <DropShadowEffect Color="#3DFF9A" BlurRadius="10" ShadowDepth="0" Opacity="0.25"/>
          </Border.Effect>
          <StackPanel Orientation="Horizontal">
            <Ellipse Fill="#3DFF9A" Width="8" Height="8" Margin="0,0,9,0" VerticalAlignment="Center">
              <Ellipse.Effect>
                <DropShadowEffect Color="#3DFF9A" BlurRadius="6" ShadowDepth="0" Opacity="0.7"/>
              </Ellipse.Effect>
            </Ellipse>
            <TextBlock x:Name="HeaderStatus" Text="READY" Foreground="#D4FFE0" FontSize="12" FontWeight="SemiBold"/>
          </StackPanel>
        </Border>
        <Button x:Name="CreateShortcutButton" Grid.Column="3" Width="170" Height="42" Margin="0,0,10,0" Style="{StaticResource DarkButton}" Content="CREATE SHORTCUT"/>
        <Button x:Name="FullscreenButton" Grid.Column="4" Width="148" Height="42" Margin="0,0,10,0" Style="{StaticResource DarkButton}" Content="WINDOWED"/>
        <Button x:Name="HideButton" Grid.Column="5" Width="48" Height="42" Style="{StaticResource DarkButton}" Content="_" FontSize="18"/>
      </Grid>
    </Border>
    <Grid Grid.Row="1" Margin="24,22,24,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="236"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <!-- Premium side panel -->
      <Border Grid.Column="0" BorderThickness="1" BorderBrush="#2E1A4A" CornerRadius="18" Padding="16,20">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#0C0E14" Offset="0"/>
            <GradientStop Color="#080A0E" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Border.Effect>
          <DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="4" Opacity="0.35"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="QUICK MODES" Foreground="#B8FF6A" FontSize="12" FontWeight="Bold" Margin="6,0,0,6"/>
            <TextBlock Text="All connected screens" Foreground="#6B7280" FontSize="11" Margin="6,0,0,16"/>
            <Button x:Name="ClearPreset" Style="{StaticResource GreenButton}" Content="CLEAR  /  0%" Height="50" Margin="0,0,0,9"/>
            <Button x:Name="ChillPreset" Style="{StaticResource DarkButton}" Content="CHILL  /  20%" Height="48" Margin="0,0,0,9"/>
            <Button x:Name="NightPreset" Style="{StaticResource DarkButton}" Content="NIGHT  /  40%" Height="48" Margin="0,0,0,9"/>
            <Button x:Name="ZombiePreset" Style="{StaticResource DarkButton}" Content="ZOMBIE  /  60%" Height="48" Margin="0,0,0,20"/>
            <Border Height="1" Margin="4,0,4,18">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="Transparent" Offset="0"/>
                  <GradientStop Color="#5B2BC7" Offset="0.5"/>
                  <GradientStop Color="Transparent" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
            <TextBlock Text="YOUR SETUP" Foreground="#A78BFA" FontSize="12" FontWeight="Bold" Margin="6,0,0,12"/>
            <Button x:Name="SaveFavorite" Style="{StaticResource DarkButton}" Content="SAVE FAVORITE" Height="46" Margin="0,0,0,8"/>
            <Button x:Name="LoadFavorite" Style="{StaticResource DarkButton}" Content="LOAD FAVORITE" Height="46" Margin="0,0,0,16"/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom">
            <Button x:Name="EmergencyReset" Style="{StaticResource GreenButton}" Content="RESET ALL SCREENS" Height="52" Margin="0,0,0,12"/>
            <TextBlock Text="Ctrl+0  ·  reset   |   F11  ·  fullscreen" FontSize="10" Foreground="#6B7280" Margin="5,0,5,4" TextWrapping="Wrap"/>
            <TextBlock Text="X hides to tray · Exit from the tray menu" FontSize="10" Foreground="#4B5563" Margin="5,0,5,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="4,0,2,18">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="SCREEN CONTROL" FontSize="26" FontWeight="Bold" Foreground="#EDE9FE"/>
            <TextBlock x:Name="ScreenSummary" Text="DETECTING YOUR DISPLAYS..." Foreground="#6B7280" FontSize="12" Margin="1,5,0,0"/>
          </StackPanel>
          <Button x:Name="RescanButton" Grid.Column="1" Style="{StaticResource DarkButton}" Content="RESCAN DISPLAYS" Width="168" Height="46" VerticalAlignment="Center"/>
        </Grid>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" PanningMode="VerticalOnly" Background="Transparent">
          <UniformGrid x:Name="ScreenCards" Columns="2" HorizontalAlignment="Stretch" VerticalAlignment="Top"/>
        </ScrollViewer>
        <Border Grid.Row="2" Margin="2,12,2,2" CornerRadius="12" BorderBrush="#2E1A4A" BorderThickness="1" Padding="16,13">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#0C0E14" Offset="0"/>
              <GradientStop Color="#080A0E" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="#6B7280" Text="SOFTWARE DIMMING  ·  Click-through overlay on each monitor. This does not change the physical backlight; exclusive fullscreen games may bypass it."/>
        </Border>
      </Grid>
    </Grid>
    <!-- Premium footer -->
    <Border Grid.Row="2" BorderBrush="#2E1A4A" BorderThickness="0,1,0,0">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#0A0C10" Offset="0"/>
          <GradientStop Color="#06080B" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Grid Margin="26,0,24,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="FooterStatus" VerticalAlignment="Center" Text="READY FOR CHAOS" Foreground="#9CA3AF" FontSize="12" FontWeight="SemiBold"/>
        <TextBlock Grid.Column="1" Text="DARKZOMBIE  v1.0.4  ·  KUSHZOMBIE SOFTWARE" Foreground="#6B7280" FontSize="11" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $XmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($WindowXaml))
    try { $script:Window = [System.Windows.Markup.XamlReader]::Load($XmlReader) }
    finally { $XmlReader.Dispose() }

    $script:TitleDragArea = $script:Window.FindName('TitleDragArea')
    $script:CreateShortcutButton = $script:Window.FindName('CreateShortcutButton')
    $script:FullscreenButton = $script:Window.FindName('FullscreenButton')
    $script:HideButton = $script:Window.FindName('HideButton')
    $script:ScreenCardsPanel = $script:Window.FindName('ScreenCards')
    $script:ScreenSummary = $script:Window.FindName('ScreenSummary')
    $script:HeaderStatus = $script:Window.FindName('HeaderStatus')
    $script:FooterStatus = $script:Window.FindName('FooterStatus')
    $script:RescanButton = $script:Window.FindName('RescanButton')

    $script:CardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="262" Margin="0,0,16,16" Padding="22,20" HorizontalAlignment="Stretch"
        BorderBrush="#2E1A4A" BorderThickness="1" CornerRadius="18">
  <Border.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#12151C" Offset="0"/>
      <GradientStop Color="#0C0E14" Offset="1"/>
    </LinearGradientBrush>
  </Border.Background>
  <Border.Effect>
    <DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="3" Opacity="0.28"/>
  </Border.Effect>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="50"/>
      <RowDefinition Height="36"/>
      <RowDefinition Height="50"/>
      <RowDefinition Height="26"/>
      <RowDefinition Height="44"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock x:Name="CardName" Text="DISPLAY" Foreground="#EDE9FE" FontSize="17" FontWeight="Bold"/>
        <TextBlock x:Name="CardDetail" Text="CONNECTING..." Foreground="#6B7280" FontSize="11" Margin="0,4,0,0"/>
      </StackPanel>
      <Border Grid.Column="1" BorderBrush="#7C3AED" BorderThickness="1" CornerRadius="10" Padding="12,6" VerticalAlignment="Top">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#1A1228" Offset="0"/>
            <GradientStop Color="#12101A" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <TextBlock x:Name="CardKind" Foreground="#C4B5FD" FontSize="10" FontWeight="SemiBold" Text="DISPLAY"/>
      </Border>
    </Grid>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="DIM LEVEL" FontSize="11" FontWeight="SemiBold" Foreground="#B8FF6A" VerticalAlignment="Center"/>
      <TextBlock Grid.Column="1" x:Name="CardValue" Text="0%" FontSize="20" FontWeight="Bold" Foreground="#B8FF6A" VerticalAlignment="Center"/>
    </Grid>
    <Slider x:Name="DimSlider" Grid.Row="2" Minimum="0" Maximum="85" VerticalAlignment="Center"/>
    <Grid Grid.Row="3" Margin="2,0,2,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="0%" Foreground="#4B5563" FontSize="10" VerticalAlignment="Center"/>
      <TextBlock Grid.Column="1" Text="CLICK OR DRAG" Foreground="#4B5563" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Center"/>
      <TextBlock Grid.Column="2" Text="85%" Foreground="#4B5563" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Right"/>
    </Grid>
    <Grid Grid.Row="4" Margin="0,6,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" CornerRadius="10" BorderBrush="#5B2BC7" BorderThickness="1" Cursor="Hand">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#161922" Offset="0"/>
            <GradientStop Color="#0F1116" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Button x:Name="LessButton" Content="−5" Height="38" FontSize="14" FontWeight="Bold" Foreground="#C4B5FD" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
      </Border>
      <TextBlock Grid.Column="1" Text="FINE CONTROL" Foreground="#6B7280" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Center"/>
      <Border Grid.Column="2" CornerRadius="10" BorderBrush="#5B2BC7" BorderThickness="1" Cursor="Hand">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#161922" Offset="0"/>
            <GradientStop Color="#0F1116" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Button x:Name="MoreButton" Content="+5" Height="38" FontSize="14" FontWeight="Bold" Foreground="#C4B5FD" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
      </Border>
    </Grid>
  </Grid>
</Border>
'@

    function Update-DZStatus {
        if (!$script:UiReady) { return }
        $count = $script:Screens.Count
        $active = 0
        foreach ($s in $script:Screens) {
            $name = [string]$s.DeviceName
            if ($script:Levels.ContainsKey($name) -and $script:Levels[$name] -gt 0) { $active++ }
        }
        $script:ScreenSummary.Text = '{0} DISPLAY(S) DETECTED   /   {1} DIMMED   /   CLICK OR DRAG THE LARGE SLIDERS' -f $count, $active
        $script:HeaderStatus.Text = if ($active -gt 0) { '{0} DIMMED' -f $active } else { 'ALL CLEAR' }
        $script:FooterStatus.Text = if ($active -gt 0) { 'DIMMING ACTIVE  |  {0} / {1} DISPLAY(S)' -f $active, $count } else { 'ALL SCREENS CLEAR  |  YOU ARE IN CONTROL' }
    }

    function Set-DZLevel([string]$DeviceName, [int]$Value) {
        $Value = [Math]::Max(0, [Math]::Min(85, $Value))
        $script:Levels[$DeviceName] = $Value
        if ($script:Overlays.ContainsKey($DeviceName)) {
            $script:Overlays[$DeviceName].SetLevel($Value)
        }
        if ($script:Cards.ContainsKey($DeviceName)) {
            $controls = $script:Cards[$DeviceName]
            $controls.Value.Text = '{0}%' -f $Value
            $controls.Border.BorderBrush = if ($Value -gt 0) { [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3DFF9A') } else { [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2E1A4A') }
            if ([int][Math]::Round($controls.Slider.Value) -ne $Value) {
                $script:ProgrammaticUpdate = $true
                try { $controls.Slider.Value = $Value }
                finally { $script:ProgrammaticUpdate = $false }
            }
        }
        Update-DZStatus
        Schedule-DZSave
    }

    function Set-DZAll([int]$Value) {
        foreach ($s in $script:Screens) { Set-DZLevel ([string]$s.DeviceName) $Value }
    }

    function Reset-DZAll {
        Set-DZAll 0
    }

    function Save-DZFavorite {
        $script:Favorite = @{}
        foreach ($s in $script:Screens) {
            $name = [string]$s.DeviceName
            $script:Favorite[$name] = [int]$script:Levels[$name]
        }
        Save-DZSettings
        $script:FooterStatus.Text = 'FAVORITE SAVED  |  YOUR EXACT PER-SCREEN SETTINGS'
    }

    function Load-DZFavorite {
        if ($script:Favorite.Count -eq 0) {
            [System.Windows.MessageBox]::Show('First adjust the sliders, then tap SAVE FAVORITE.', 'DarkZombie', 'OK', 'Information') | Out-Null
            return
        }
        foreach ($s in $script:Screens) {
            $name = [string]$s.DeviceName
            if ($script:Favorite.ContainsKey($name)) {
                Set-DZLevel $name ([int]$script:Favorite[$name])
            }
        }
        $script:FooterStatus.Text = 'FAVORITE LOADED  |  PERSONAL MONITOR LEVELS RESTORED'
    }

    function New-DZDesktopShortcut {
        try {
            $exePath = Join-Path $script:Root 'DarkZombie.exe'
            $iconPath = Join-Path $script:Root 'DarkZombie.ico'
            if (!(Test-Path -LiteralPath $exePath)) {
                throw 'DarkZombie.exe is missing. Please extract the complete ZIP first.'
            }
            $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
            if ([string]::IsNullOrWhiteSpace($desktop) -or !(Test-Path -LiteralPath $desktop)) {
                throw 'Windows could not locate the Desktop folder.'
            }
            $lnkPath = Join-Path $desktop 'DarkZombie.lnk'
            $shell = New-Object -ComObject WScript.Shell
            try {
                $shortcut = $shell.CreateShortcut($lnkPath)
                $shortcut.TargetPath = $exePath
                $shortcut.WorkingDirectory = $script:Root
                $shortcut.Description = 'DarkZombie | KushZombie Software - Display Dimmer'
                if (Test-Path -LiteralPath $iconPath) {
                    $shortcut.IconLocation = ('{0},0' -f $iconPath)
                } else {
                    $shortcut.IconLocation = ('{0},0' -f $exePath)
                }
                $shortcut.Save()
            } finally {
                if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
            }
            $script:FooterStatus.Text = 'DESKTOP SHORTCUT CREATED  |  DARKZOMBIE'
            [System.Windows.MessageBox]::Show(
                'DarkZombie desktop shortcut created. Keep the extracted DarkZombie folder in this location so the shortcut continues to work.',
                'DarkZombie - Shortcut ready',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information) | Out-Null
        } catch {
            Write-DZLog ('Could not create desktop shortcut: ' + $_.Exception.Message)
            [System.Windows.MessageBox]::Show(
                ('Could not create the desktop shortcut: ' + $_.Exception.Message),
                'DarkZombie - Shortcut',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
    }

    function Refresh-DZDisplays {
        # Dispose the old visual overlays first. Does not affect existing Aubum services.
        foreach ($old in @($script:Overlays.Values)) {
            try { $old.SetLevel(0); $old.Close(); $old.Dispose() } catch { Write-DZLog $_.Exception.Message }
        }
        $script:Overlays.Clear()
        $script:Cards.Clear()
        $script:ScreenCardsPanel.Children.Clear()
        $script:Screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
        $index = 0
        foreach ($s in $script:Screens) {
            $index++
            $name = [string]$s.DeviceName
            if (!$script:Levels.ContainsKey($name)) { $script:Levels[$name] = 0 }
            $overlay = [DarkZombie.ScreenOverlay]::new($s.Bounds)
            $script:Overlays[$name] = $overlay

            $cr = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($script:CardXaml))
            try { $card = [System.Windows.Markup.XamlReader]::Load($cr) }
            finally { $cr.Dispose() }
            $n = $card.FindName('CardName')
            $d = $card.FindName('CardDetail')
            $k = $card.FindName('CardKind')
            $v = $card.FindName('CardValue')
            $slider = $card.FindName('DimSlider')
            $minus = $card.FindName('LessButton')
            $plus = $card.FindName('MoreButton')
            $n.Text = 'DISPLAY {0:00}' -f $index
            $d.Text = '{0} x {1}   /   {2}' -f $s.Bounds.Width, $s.Bounds.Height, $name
            $k.Text = if ($s.Primary) { 'PRIMARY' } else { 'EXTENDED' }
            $slider.Style = $script:Window.FindResource('NeonSlider')
            $slider.Tag = $name
            $minus.Tag = $name
            $plus.Tag = $name
            $script:Cards[$name] = @{ Border = $card; Slider = $slider; Value = $v }
            [void]$script:ScreenCardsPanel.Children.Add($card)

            $slider.Add_ValueChanged({
                param($sender, $eventArgs)
                if ($script:ProgrammaticUpdate) { return }
                Set-DZLevel ([string]$sender.Tag) ([int][Math]::Round($sender.Value))
            })
            $minus.Add_Click({
                param($sender, $eventArgs)
                $id = [string]$sender.Tag
                Set-DZLevel $id ([int]$script:Levels[$id] - 5)
            })
            $plus.Add_Click({
                param($sender, $eventArgs)
                $id = [string]$sender.Tag
                Set-DZLevel $id ([int]$script:Levels[$id] + 5)
            })
            Set-DZLevel $name ([int]$script:Levels[$name])
        }
        $script:UiReady = $true
        Update-DZStatus
        # Keep touch controls visible in front of click-through overlays.
        $script:Window.Topmost = $true
        $script:Window.Activate() | Out-Null
    }

    function Enter-DZFullscreen {
        if ($script:IsFullscreen) { return }
        $script:SavedWindow = @{
            Left = $script:Window.Left
            Top = $script:Window.Top
            Width = $script:Window.Width
            Height = $script:Window.Height
        }
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:Window)
        $target = [System.Windows.Forms.Screen]::FromHandle($helper.Handle)
        $src = [System.Windows.PresentationSource]::FromVisual($script:Window)
        $transform = $src.CompositionTarget.TransformFromDevice
        $xy = $transform.Transform([System.Windows.Point]::new($target.Bounds.Left, $target.Bounds.Top))
        $wh = $transform.Transform([System.Windows.Point]::new($target.Bounds.Width, $target.Bounds.Height))
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
        $script:Window.WindowStyle = [System.Windows.WindowStyle]::None
        $script:Window.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $script:Window.Left = $xy.X
        $script:Window.Top = $xy.Y
        $script:Window.Width = $wh.X
        $script:Window.Height = $wh.Y
        $script:Window.Topmost = $true
        $script:IsFullscreen = $true
        $script:FullscreenButton.Content = 'WINDOWED'
    }

    function Leave-DZFullscreen {
        if (!$script:IsFullscreen) { return }
        $script:IsFullscreen = $false
        $script:Window.Topmost = $false
        $script:Window.WindowStyle = [System.Windows.WindowStyle]::SingleBorderWindow
        $script:Window.ResizeMode = [System.Windows.ResizeMode]::CanResize
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
        if ($null -ne $script:SavedWindow) {
            $script:Window.Left = $script:SavedWindow.Left
            $script:Window.Top = $script:SavedWindow.Top
            $script:Window.Width = $script:SavedWindow.Width
            $script:Window.Height = $script:SavedWindow.Height
        }
        $script:FullscreenButton.Content = 'FULLSCREEN'
    }

    function Toggle-DZFullscreen {
        if ($script:IsFullscreen) { Leave-DZFullscreen } else { Enter-DZFullscreen }
    }

    function Show-DZWindow {
        if (!$script:Window.IsVisible) { $script:Window.Show() }
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
        $script:Window.Topmost = $true
        $script:Window.Activate() | Out-Null
    }

    function Exit-DZ {
        if ($script:Exiting) { return }
        $script:Exiting = $true
        try { Save-DZSettings } catch { }
        foreach ($overlay in @($script:Overlays.Values)) {
            try { $overlay.SetLevel(0); $overlay.Close(); $overlay.Dispose() } catch { }
        }
        $script:Overlays.Clear()
        try { if ($null -ne $script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
        if ($null -ne $script:ActivationTimer) { $script:ActivationTimer.Stop() }
        try { if ($null -ne $script:ActivationSignal) { $script:ActivationSignal.Dispose() } } catch { }
        try { if ($null -ne $script:SingletonMutex) { $script:SingletonMutex.ReleaseMutex(); $script:SingletonMutex.Dispose() } } catch { }
        $script:Window.Close()
    }

    $script:ActivationTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:ActivationTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:ActivationTimer.Add_Tick({
        if ($null -ne $script:ActivationSignal -and $script:ActivationSignal.WaitOne(0)) {
            Show-DZWindow
        }
    })
    $script:ActivationTimer.Start()

    $script:SaveTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:SaveTimer.Interval = [TimeSpan]::FromMilliseconds(750)
    $script:SaveTimer.Add_Tick({
        $script:SaveTimer.Stop()
        Save-DZSettings
    })

    $script:Tray = [System.Windows.Forms.NotifyIcon]::new()
    $iconPath = Join-Path $script:Root 'DarkZombie.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $script:Tray.Icon = [System.Drawing.Icon]::new($iconPath)
            $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath, [UriKind]::Absolute))
        } catch {
            Write-DZLog ('Custom icon could not load; using standard icon: ' + $_.Exception.Message)
            $script:Tray.Icon = [System.Drawing.SystemIcons]::Application
        }
    } else { $script:Tray.Icon = [System.Drawing.SystemIcons]::Application }
    $script:Tray.Text = 'DarkZombie - KushZombie Software'
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $showItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open DarkZombie')
    $shortcutItem = [System.Windows.Forms.ToolStripMenuItem]::new('Create Desktop Shortcut')
    $resetItem = [System.Windows.Forms.ToolStripMenuItem]::new('RESET ALL DIMMING')
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit DarkZombie')
    [void]$menu.Items.Add($showItem)
    [void]$menu.Items.Add($shortcutItem)
    [void]$menu.Items.Add($resetItem)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menu.Items.Add($exitItem)
    $script:Tray.ContextMenuStrip = $menu
    $showItem.Add_Click({ Show-DZWindow })
    $shortcutItem.Add_Click({ New-DZDesktopShortcut })
    $resetItem.Add_Click({ Reset-DZAll })
    $exitItem.Add_Click({ Exit-DZ })
    $script:Tray.Add_DoubleClick({ Show-DZWindow })
    $script:Tray.Visible = $true

    $script:Window.FindName('ClearPreset').Add_Click({ Set-DZAll 0 })
    $script:Window.FindName('ChillPreset').Add_Click({ Set-DZAll 20 })
    $script:Window.FindName('NightPreset').Add_Click({ Set-DZAll 40 })
    $script:Window.FindName('ZombiePreset').Add_Click({ Set-DZAll 60 })
    $script:Window.FindName('SaveFavorite').Add_Click({ Save-DZFavorite })
    $script:Window.FindName('LoadFavorite').Add_Click({ Load-DZFavorite })
    $script:Window.FindName('EmergencyReset').Add_Click({ Reset-DZAll })
    $script:RescanButton.Add_Click({ Refresh-DZDisplays })
    $script:CreateShortcutButton.Add_Click({ New-DZDesktopShortcut })
    $script:FullscreenButton.Add_Click({ Toggle-DZFullscreen })
    $script:HideButton.Add_Click({ $script:Window.Hide() })
    $script:TitleDragArea.Add_MouseLeftButtonDown({ if (!$script:IsFullscreen) { $script:Window.DragMove() } })

    $script:Window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::F11) {
            Toggle-DZFullscreen
            $eventArgs.Handled = $true
        } elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape -and $script:IsFullscreen) {
            Leave-DZFullscreen
            $eventArgs.Handled = $true
        } elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::D0 -and
                  (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
            Reset-DZAll
            $eventArgs.Handled = $true
        }
    })
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        if (!$script:Exiting) {
            $eventArgs.Cancel = $true
            $script:Window.Hide()
        }
    })
    $script:Window.Add_Loaded({
        try {
            Refresh-DZDisplays
            if (!$Windowed) { Enter-DZFullscreen }
        } catch {
            Write-DZLog ('Initialization failure: ' + $_.Exception.ToString())
            [System.Windows.MessageBox]::Show(('DarkZombie could not initialize its overlays: ' + $_.Exception.Message), 'DarkZombie', 'OK', 'Error') | Out-Null
        }
    })

    [void]$script:Window.ShowDialog()
    # If the window ever exits independently, remove all dimming overlays.
    foreach ($overlay in @($script:Overlays.Values)) {
        try { $overlay.SetLevel(0); $overlay.Close(); $overlay.Dispose() } catch { }
    }
    if ($null -ne $script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    try { if ($null -ne $script:ActivationSignal) { $script:ActivationSignal.Dispose() } } catch { }
    try { if ($null -ne $script:SingletonMutex) { $script:SingletonMutex.ReleaseMutex(); $script:SingletonMutex.Dispose() } } catch { }

} catch {
    Write-DZLog ('FATAL: ' + $_.Exception.ToString())
    foreach ($overlay in @($script:Overlays.Values)) { try { $overlay.Dispose() } catch { } }
    try { if ($null -ne $script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    try { if ($null -ne $script:ActivationSignal) { $script:ActivationSignal.Dispose() } } catch { }
    try { if ($null -ne $script:SingletonMutex) { $script:SingletonMutex.ReleaseMutex(); $script:SingletonMutex.Dispose() } } catch { }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            'DarkZombie could not start. See:' + [Environment]::NewLine + $script:LogPath +
            [Environment]::NewLine + $_.Exception.Message,
            'DarkZombie - startup error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
    exit 1
}