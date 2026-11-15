/*
 * Swiftify, a spotify player for desktop
 * Copyright (C) 2026  shred0s
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "system/windows/WindowsIntegration.h"

#include "playback/PlaybackController.h"
#include "theme/Theme.h"

#include <QApplication>
#include <QImage>
#include <QPlatformSurfaceEvent>
#include <QQuickWindow>
#include <QSet>
#include <QStyle>
#include <QTimer>
#include <QWindow>

#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shobjidl.h>

#ifdef SWIFTIFY_HAVE_SMTC
// mingw-w64's windows.foundation.h specialises IReference for BYTE and for
// boolean, which it also makes an unsigned char; nothing here uses either
#ifdef __MINGW32__
#define ____FIReference_1_boolean_INTERFACE_DEFINED__
#endif
#include <roapi.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.media.h>
#include <systemmediatransportcontrolsinterop.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cwchar>
#include <functional>
#include <limits>

namespace swiftify {

namespace {

constexpr UINT kPrevious = 1;
constexpr UINT kPlayPause = 2;
constexpr UINT kNext = 3;
constexpr DWORD kImmersiveDarkMode = 20;
constexpr DWORD kCornerPreference = 33;
constexpr DWORD kBorderColor = 34;
constexpr DWORD kCaptionColor = 35;
constexpr DWORD kTextColor = 36;

COLORREF nativeColor(const QColor &color)
{
    return RGB(color.red(), color.green(), color.blue());
}

#ifdef SWIFTIFY_HAVE_SMTC
// written out by hand instead of wrl's Callback (<wrl/event.h>), which only msvc ships
template <typename Handler, typename Args, typename Value, HRESULT (STDMETHODCALLTYPE Args::*Getter)(Value *)>
class SmtcEventCallback final : public Handler
{
public:
    using Function = std::function<void(Value)>;

    explicit SmtcEventCallback(Function function)
        : m_function(std::move(function))
    {
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override
    {
        if (!object) return E_POINTER;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IAgileObject)
            || IsEqualIID(riid, __uuidof(Handler))) {
            *object = static_cast<Handler *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++m_references; }

    ULONG STDMETHODCALLTYPE Release() override
    {
        const ULONG remaining = --m_references;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE Invoke(ABI::Windows::Media::ISystemMediaTransportControls *, Args *args) override
    {
        Value value {};
        if (args && SUCCEEDED((args->*Getter)(&value))) {
            m_function(value);
        }
        return S_OK;
    }

private:
    std::atomic<ULONG> m_references {1};
    Function m_function;
};
#endif

} // namespace

struct WindowsIntegration::Native {
    ITaskbarList3 *taskbar = nullptr;
    UINT taskbarCreated = RegisterWindowMessageW(L"TaskbarButtonCreated");
    bool ownsCom = false;
    bool buttonsAdded = false;
    QSet<quintptr> readyWindows;
    HWND handle = nullptr;
    std::array<HICON, 4> icons {};

#ifdef SWIFTIFY_HAVE_SMTC
    Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> controls;
    Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls2> controls2;
    EventRegistrationToken buttonToken {};
    EventRegistrationToken positionToken {};
    EventRegistrationToken shuffleToken {};
    EventRegistrationToken repeatToken {};
#endif

    Native()
    {
        ownsCom = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
        const std::array<QStyle::StandardPixmap, 4> symbols {
            QStyle::SP_MediaSkipBackward, QStyle::SP_MediaPlay,
            QStyle::SP_MediaPause, QStyle::SP_MediaSkipForward
        };
        for (size_t index = 0; index < symbols.size(); ++index) {
            icons[index] = QApplication::style()->standardIcon(symbols[index]).pixmap(24).toImage().toHICON();
        }
    }

    void cleanupMediaControls()
    {
#ifdef SWIFTIFY_HAVE_SMTC
        if (controls2) {
            if (positionToken.value != 0) {
                controls2->remove_PlaybackPositionChangeRequested(positionToken);
                positionToken.value = 0;
            }
            if (shuffleToken.value != 0) {
                controls2->remove_ShuffleEnabledChangeRequested(shuffleToken);
                shuffleToken.value = 0;
            }
            if (repeatToken.value != 0) {
                controls2->remove_AutoRepeatModeChangeRequested(repeatToken);
                repeatToken.value = 0;
            }
            controls2.Reset();
        }
        if (controls) {
            if (buttonToken.value != 0) {
                controls->remove_ButtonPressed(buttonToken);
                buttonToken.value = 0;
            }
            controls->put_IsEnabled(false);
            controls.Reset();
        }
#endif
    }

    ~Native()
    {
        if (handle) RemoveWindowSubclass(handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(this));
        if (taskbar) {
            taskbar->Release();
        }
        for (HICON icon : icons) {
            if (icon) DestroyIcon(icon);
        }
        cleanupMediaControls();
        if (ownsCom) CoUninitialize();
    }

    static LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam,
                                            UINT_PTR identity, DWORD_PTR context)
    {
        auto *integration = reinterpret_cast<WindowsIntegration *>(context);
        if (message == WM_THEMECHANGED || message == WM_DWMCOMPOSITIONCHANGED || message == WM_STYLECHANGED) {
            QTimer::singleShot(0, integration, &WindowsIntegration::styleWindow);
        }
        const bool customFrame = integration->m_window
            && integration->m_window->flags().testFlag(Qt::FramelessWindowHint)
            && integration->m_window->visibility() != QWindow::FullScreen;
        if (customFrame) {
            if (message == WM_NCCALCSIZE) {
                if (wParam && IsZoomed(window)) {
                    auto *bounds = &reinterpret_cast<NCCALCSIZE_PARAMS *>(lParam)->rgrc[0];
                    MONITORINFO monitor {sizeof(MONITORINFO)};
                    if (GetMonitorInfoW(MonitorFromRect(bounds, MONITOR_DEFAULTTONEAREST), &monitor)) {
                        *bounds = monitor.rcWork;
                    }
                }
                return 0;
            }
            if (message == WM_NCHITTEST) {
                if (IsZoomed(window)) {
                    return HTCLIENT;
                }
                RECT bounds {};
                if (GetWindowRect(window, &bounds)) {
                    using WindowDpi = UINT (WINAPI *)(HWND);
                    using MetricsForDpi = int (WINAPI *)(int, UINT);
                    static const auto windowDpi = reinterpret_cast<WindowDpi>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
                    static const auto metricsForDpi = reinterpret_cast<MetricsForDpi>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetSystemMetricsForDpi"));
                    const UINT dpi = windowDpi ? windowDpi(window) : qRound(96 * integration->m_window->devicePixelRatio());
                    const int borderX = metricsForDpi
                        ? metricsForDpi(SM_CXSIZEFRAME, dpi) + metricsForDpi(SM_CXPADDEDBORDER, dpi)
                        : GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
                    const int borderY = metricsForDpi
                        ? metricsForDpi(SM_CYSIZEFRAME, dpi) + metricsForDpi(SM_CXPADDEDBORDER, dpi)
                        : GetSystemMetrics(SM_CYSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
                    const int horizontal = GET_X_LPARAM(lParam);
                    const int vertical = GET_Y_LPARAM(lParam);
                    const bool left = horizontal >= bounds.left && horizontal < bounds.left + borderX;
                    const bool right = horizontal < bounds.right && horizontal >= bounds.right - borderX;
                    const bool top = vertical >= bounds.top && vertical < bounds.top + borderY;
                    const bool bottom = vertical < bounds.bottom && vertical >= bounds.bottom - borderY;
                    if (top && left) return HTTOPLEFT;
                    if (top && right) return HTTOPRIGHT;
                    if (bottom && left) return HTBOTTOMLEFT;
                    if (bottom && right) return HTBOTTOMRIGHT;
                    if (left) return HTLEFT;
                    if (right) return HTRIGHT;
                    if (top) return HTTOP;
                    if (bottom) return HTBOTTOM;
                    if (horizontal >= bounds.left && horizontal < bounds.right
                        && vertical >= bounds.top && vertical < bounds.bottom) {
                        return HTCLIENT;
                    }
                }
            }
        }
        if (message == WM_COMMAND && HIWORD(wParam) == THBN_CLICKED) {
            MSG native {};
            native.hwnd = window;
            native.message = message;
            native.wParam = wParam;
            native.lParam = lParam;
            qintptr result = 0;
            if (integration->nativeEventFilter(QByteArrayLiteral("windows_generic_MSG"), &native, &result)) return result;
        } else if (message == WM_NCDESTROY) {
            RemoveWindowSubclass(window, &Native::windowProcedure, identity);
            integration->m_native->cleanupMediaControls();
            integration->m_native->handle = nullptr;
            integration->m_native->buttonsAdded = false;
            integration->m_native->readyWindows.remove(reinterpret_cast<quintptr>(window));
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }
};

void WindowsIntegration::initializeProcess()
{
    SetCurrentProcessExplicitAppUserModelID(L"dev.addenator.Swiftify.Qt");
    const HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    if ((err && err != INVALID_HANDLE_VALUE && GetFileType(err) != FILE_TYPE_UNKNOWN)
        || AttachConsole(ATTACH_PARENT_PROCESS)) {
        if (!qEnvironmentVariableIsSet("QT_FORCE_STDERR_LOGGING")) {
            qputenv("QT_FORCE_STDERR_LOGGING", "1");
        }
    }
}

void WindowsIntegration::setNativeTitleBar(QWindow *window, bool enabled)
{
    if (!window) return;
    const Qt::WindowFlags flags = enabled
        ? Qt::Window | Qt::WindowTitleHint | Qt::WindowSystemMenuHint | Qt::WindowMinMaxButtonsHint | Qt::WindowCloseButtonHint
        : Qt::Window | Qt::FramelessWindowHint;
    if (window->flags() == flags) return;
    if (!window->handle() || QGuiApplication::platformName() != QLatin1StringView("windows")) {
        window->setFlags(flags);
        return;
    }
    WINDOWPLACEMENT placement {sizeof(WINDOWPLACEMENT)};
    const bool placed = GetWindowPlacement(reinterpret_cast<HWND>(window->winId()), &placement);
    const auto visibility = window->visibility();
    const auto states = window->windowStates();
    const bool active = window->isActive();
    window->hide();
    window->destroy();
    window->setWindowStates(Qt::WindowNoState);
    window->setFlags(flags);
    window->create();
    if (placed) {
        placement.showCmd = SW_HIDE;
        SetWindowPlacement(reinterpret_cast<HWND>(window->winId()), &placement);
    }
    window->setWindowStates(states);
    window->setVisibility(visibility);
    if (active && window->isVisible()) window->requestActivate();
}

WindowsIntegration::WindowsIntegration(PlaybackController *player, Theme *theme, QObject *parent)
    : QObject(parent), m_player(player), m_theme(theme)
{
    if (QGuiApplication::platformName() != QLatin1StringView("windows")) {
        return;
    }
    m_native = std::make_unique<Native>();
    qApp->installNativeEventFilter(this);
    connect(m_theme, &Theme::schemeChanged, this, &WindowsIntegration::styleWindow);
    connect(m_player, &PlaybackController::playingChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::playingChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::playingChanged, this, &WindowsIntegration::updateMediaTimeline);
    connect(m_player, &PlaybackController::queueChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::queueChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateMediaMetadata);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateMediaTimeline);
    connect(m_player, &PlaybackController::mediaStateChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::mediaStateChanged, this, &WindowsIntegration::updateMediaMetadata);
    connect(m_player, &PlaybackController::shuffleChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::repeatModeChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::loadingChanged, this, &WindowsIntegration::updateProgress);
    connect(m_player, &PlaybackController::livePositionChanged, this, &WindowsIntegration::updateProgress);
    connect(m_player, &PlaybackController::positionChanged, this, &WindowsIntegration::updateMediaTimeline);
    connect(m_player, &PlaybackController::durationChanged, this, &WindowsIntegration::updateProgress);
    connect(m_player, &PlaybackController::durationChanged, this, &WindowsIntegration::updateMediaTimeline);
}

WindowsIntegration::~WindowsIntegration()
{
    if (m_native) {
        qApp->removeNativeEventFilter(this);
        m_native->cleanupMediaControls();
        if (m_window && m_native->taskbar) {
            m_native->taskbar->SetProgressState(reinterpret_cast<HWND>(m_window->winId()), TBPF_NOPROGRESS);
        }
    }
}

void WindowsIntegration::setWindow(QWindow *window)
{
    if (m_window == window || !m_native) {
        return;
    }
    if (m_window) {
        m_window->removeEventFilter(this);
        disconnect(m_window, nullptr, this, nullptr);
    }
    if (m_native->handle) {
        RemoveWindowSubclass(m_native->handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()));
        m_native->cleanupMediaControls();
        m_native->handle = nullptr;
    }
    m_window = window;
    m_native->buttonsAdded = false;
    if (!m_window) return;
    m_window->installEventFilter(this);
    m_window->create();
    attachWindow();
    connect(m_window, &QWindow::visibleChanged, this, [this](bool visible) {
        if (visible) {
            styleWindow();
            QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
            QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
        }
    });
    if (auto *quick = qobject_cast<QQuickWindow *>(m_window.data())) {
        connect(quick, &QQuickWindow::colorChanged, this, &WindowsIntegration::styleWindow);
    }
    styleWindow();
    QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
    QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
}

void WindowsIntegration::attachWindow()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (m_native->handle == handle) return;
    if (m_native->handle) {
        RemoveWindowSubclass(m_native->handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()));
    }
    m_native->handle = nullptr;
    m_native->buttonsAdded = false;
    if (SetWindowSubclass(handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()),
                          reinterpret_cast<DWORD_PTR>(this))) {
        m_native->handle = handle;
    }
}

bool WindowsIntegration::eventFilter(QObject *watched, QEvent *event)
{
    if (watched == m_window && event->type() == QEvent::PlatformSurface) {
        const auto *surface = static_cast<QPlatformSurfaceEvent *>(event);
        if (surface->surfaceEventType() == QPlatformSurfaceEvent::SurfaceCreated) {
            styleWindow();
            QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
            QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
        }
    }
    return QObject::eventFilter(watched, event);
}

void WindowsIntegration::styleWindow()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    attachWindow();
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    const bool customFrame = m_window->flags().testFlag(Qt::FramelessWindowHint) && m_window->visibility() != QWindow::FullScreen;
    if (customFrame) {
        const LONG_PTR current = GetWindowLongPtrW(handle, GWL_STYLE);
        const LONG_PTR desired = (current | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU) & ~WS_POPUP;
        if (current != desired) {
            SetWindowLongPtrW(handle, GWL_STYLE, desired);
            SetWindowPos(handle, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }
    const BOOL transitionsDisabled = FALSE;
    DwmSetWindowAttribute(handle, DWMWA_TRANSITIONS_FORCEDISABLED, &transitionsDisabled, sizeof(transitionsDisabled));
    const MARGINS margins = customFrame ? MARGINS{0, 0, 0, 1} : MARGINS{0, 0, 0, 0};
    DwmExtendFrameIntoClientArea(handle, &margins);
    const auto *quick = qobject_cast<QQuickWindow *>(m_window.data());
    const QColor background = quick ? quick->color() : m_theme->colors()->layer0();
    const BOOL dark = background.lightnessF() < 0.5;
    const DWORD corners = 2;
    const COLORREF border = 0xfffffffe;
    const COLORREF caption = nativeColor(background);
    const COLORREF text = dark ? RGB(255, 255, 255) : RGB(0, 0, 0);
    DwmSetWindowAttribute(handle, kImmersiveDarkMode, &dark, sizeof(dark));
    DwmSetWindowAttribute(handle, kCornerPreference, &corners, sizeof(corners));
    DwmSetWindowAttribute(handle, kBorderColor, &border, sizeof(border));
    DwmSetWindowAttribute(handle, kCaptionColor, &caption, sizeof(caption));
    DwmSetWindowAttribute(handle, kTextColor, &text, sizeof(text));
}

void WindowsIntegration::initializeTaskbar()
{
    if (!m_window || !m_native || !m_window->isVisible()) return;
    if (!m_native->readyWindows.contains(quintptr(m_window->winId()))) return;
    if (!m_native->taskbar) {
        if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_ITaskbarList3, reinterpret_cast<void **>(&m_native->taskbar)))) {
            return;
        }
        if (FAILED(m_native->taskbar->HrInit())) {
            m_native->taskbar->Release();
            m_native->taskbar = nullptr;
            return;
        }
    }
    updateButtons();
}

void WindowsIntegration::updateButtons()
{
    if (!m_window || !m_native || !m_native->taskbar || !m_window->isVisible()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    std::array<THUMBBUTTON, 3> buttons {};
    const std::array<HICON, 3> icons {
        m_native->icons[0], m_native->icons[m_player->isPlaying() ? 2 : 1], m_native->icons[3]
    };
    const std::array<const wchar_t *, 3> tips {
        L"Previous", m_player->isPlaying() ? L"Pause" : L"Play", L"Next"
    };
    const std::array<bool, 3> enabled {
        m_player->hasSong(), m_player->hasSong(), m_player->canSkipForward()
    };
    for (size_t index = 0; index < buttons.size(); ++index) {
        buttons[index].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        buttons[index].iId = UINT(index) + 1;
        buttons[index].hIcon = icons[index];
        buttons[index].dwFlags = enabled[index] ? THBF_ENABLED : THBF_DISABLED;
        std::wcsncpy(buttons[index].szTip, tips[index], std::size(buttons[index].szTip) - 1);
    }
    if (!m_native->buttonsAdded) {
        m_native->buttonsAdded = SUCCEEDED(m_native->taskbar->ThumbBarAddButtons(handle, UINT(buttons.size()), buttons.data()));
    } else {
        m_native->taskbar->ThumbBarUpdateButtons(handle, UINT(buttons.size()), buttons.data());
    }
    const Song song = m_player->currentSong();
    const QString tooltip = m_player->hasSong() ? song.name + QStringLiteral(" — ") + song.artists : QStringLiteral("Swiftify");
    m_native->taskbar->SetThumbnailTooltip(handle, reinterpret_cast<LPCWSTR>(tooltip.utf16()));
    updateProgress();
}

void WindowsIntegration::updateProgress()
{
    if (!m_window || !m_native || !m_native->taskbar || !m_window->isVisible()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (!m_player->hasSong()) {
        m_native->taskbar->SetProgressState(handle, TBPF_NOPROGRESS);
    } else if (m_player->isLoading()) {
        m_native->taskbar->SetProgressState(handle, TBPF_INDETERMINATE);
    } else if (m_player->durationMs() > 0) {
        m_native->taskbar->SetProgressState(handle, m_player->isPlaying() ? TBPF_NORMAL : TBPF_PAUSED);
        m_native->taskbar->SetProgressValue(handle,
            std::min<quint64>(m_player->livePositionMs(), m_player->durationMs()), m_player->durationMs());
    } else {
        m_native->taskbar->SetProgressState(handle, TBPF_NOPROGRESS);
    }
}

bool WindowsIntegration::nativeEventFilter(const QByteArray &eventType, void *message, qintptr *result)
{
    if (!m_native || (eventType != "windows_generic_MSG" && eventType != "windows_dispatcher_MSG")) return false;
    const auto *native = static_cast<MSG *>(message);
    if (m_native->taskbarCreated && native->message == m_native->taskbarCreated) {
        m_native->readyWindows.insert(reinterpret_cast<quintptr>(native->hwnd));
        if (!m_window || !m_window->handle() || native->hwnd != reinterpret_cast<HWND>(m_window->winId())) return false;
        m_native->buttonsAdded = false;
        if (m_native->taskbar) {
            m_native->taskbar->Release();
            m_native->taskbar = nullptr;
        }
        initializeTaskbar();
        return false;
    }
    if (!m_window || !m_window->handle() || native->hwnd != reinterpret_cast<HWND>(m_window->winId())) return false;
    if (native->message == WM_COMMAND && HIWORD(native->wParam) == THBN_CLICKED) {
        switch (LOWORD(native->wParam)) {
        case kPrevious: m_player->skipBackward(); break;
        case kPlayPause: m_player->togglePlayback(); break;
        case kNext: m_player->skipForward(); break;
        default: return false;
        }
        if (result) *result = 0;
        return true;
    }
    return false;
}

#ifdef SWIFTIFY_HAVE_SMTC
void WindowsIntegration::initializeMediaControls()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (m_native->controls) return;

    using namespace ABI::Windows::Media;
    using namespace ABI::Windows::Foundation;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HStringReference;

    ComPtr<ISystemMediaTransportControlsInterop> interop;
    HStringReference smtcId(RuntimeClass_Windows_Media_SystemMediaTransportControls);
    if (FAILED(RoGetActivationFactory(smtcId.Get(), IID_PPV_ARGS(&interop))) || !interop) {
        return;
    }

    if (FAILED(interop->GetForWindow(handle, IID_PPV_ARGS(&m_native->controls))) || !m_native->controls) {
        return;
    }

    m_native->controls->put_IsEnabled(true);
    m_native->controls->put_IsPlayEnabled(true);
    m_native->controls->put_IsPauseEnabled(true);
    m_native->controls->put_IsStopEnabled(true);
    m_native->controls->put_IsNextEnabled(true);
    m_native->controls->put_IsPreviousEnabled(true);

    using ButtonPressedHandler = ITypedEventHandler<SystemMediaTransportControls *, SystemMediaTransportControlsButtonPressedEventArgs *>;
    using ButtonPressedCallback = SmtcEventCallback<
        ButtonPressedHandler, ISystemMediaTransportControlsButtonPressedEventArgs,
        SystemMediaTransportControlsButton, &ISystemMediaTransportControlsButtonPressedEventArgs::get_Button>;

    m_native->buttonToken.value = 0;
    // the buttons are pressed on a thread of windows' own; the press is
    // queued onto this one
    ComPtr<ButtonPressedHandler> handler;
    handler.Attach(new ButtonPressedCallback([this](SystemMediaTransportControlsButton button) {
        QMetaObject::invokeMethod(this, [this, button] {
            handleMediaButton(int(button));
        }, Qt::QueuedConnection);
    }));
    m_native->controls->add_ButtonPressed(handler.Get(), &m_native->buttonToken);

    if (SUCCEEDED(m_native->controls.As(&m_native->controls2)) && m_native->controls2) {
        using PositionHandler = ITypedEventHandler<SystemMediaTransportControls *, PlaybackPositionChangeRequestedEventArgs *>;
        using PositionCallback = SmtcEventCallback<
            PositionHandler, IPlaybackPositionChangeRequestedEventArgs,
            TimeSpan, &IPlaybackPositionChangeRequestedEventArgs::get_RequestedPlaybackPosition>;
        ComPtr<PositionHandler> positionHandler;
        positionHandler.Attach(new PositionCallback([this](TimeSpan position) {
            const int positionMs = int(qBound<qint64>(0, position.Duration / 10000LL, std::numeric_limits<int>::max()));
            QMetaObject::invokeMethod(this, [this, positionMs] {
                m_player->seek(positionMs);
            }, Qt::QueuedConnection);
        }));
        m_native->controls2->add_PlaybackPositionChangeRequested(positionHandler.Get(), &m_native->positionToken);

        using ShuffleHandler = ITypedEventHandler<SystemMediaTransportControls *, ShuffleEnabledChangeRequestedEventArgs *>;
        using ShuffleCallback = SmtcEventCallback<
            ShuffleHandler, IShuffleEnabledChangeRequestedEventArgs,
            boolean, &IShuffleEnabledChangeRequestedEventArgs::get_RequestedShuffleEnabled>;
        ComPtr<ShuffleHandler> shuffleHandler;
        shuffleHandler.Attach(new ShuffleCallback([this](boolean enabled) {
            const bool requested = enabled != 0;
            QMetaObject::invokeMethod(this, [this, requested] {
                if (requested != m_player->isShuffleEnabled()) {
                    m_player->toggleShuffle();
                }
            }, Qt::QueuedConnection);
        }));
        m_native->controls2->add_ShuffleEnabledChangeRequested(shuffleHandler.Get(), &m_native->shuffleToken);

        using RepeatHandler = ITypedEventHandler<SystemMediaTransportControls *, AutoRepeatModeChangeRequestedEventArgs *>;
        using RepeatCallback = SmtcEventCallback<
            RepeatHandler, IAutoRepeatModeChangeRequestedEventArgs,
            MediaPlaybackAutoRepeatMode, &IAutoRepeatModeChangeRequestedEventArgs::get_RequestedAutoRepeatMode>;
        ComPtr<RepeatHandler> repeatHandler;
        repeatHandler.Attach(new RepeatCallback([this](MediaPlaybackAutoRepeatMode mode) {
            PlaybackController::RepeatMode target = PlaybackController::RepeatMode::Off;
            if (mode == MediaPlaybackAutoRepeatMode_List) target = PlaybackController::RepeatMode::All;
            else if (mode == MediaPlaybackAutoRepeatMode_Track) target = PlaybackController::RepeatMode::One;
            QMetaObject::invokeMethod(this, [this, target] {
                m_player->setRepeatMode(target);
            }, Qt::QueuedConnection);
        }));
        m_native->controls2->add_AutoRepeatModeChangeRequested(repeatHandler.Get(), &m_native->repeatToken);
    }

    updateMediaMetadata();
    updateMediaControls();
    updateMediaTimeline();
}

void WindowsIntegration::handleMediaButton(int button)
{
    using namespace ABI::Windows::Media;
    switch (button) {
    case SystemMediaTransportControlsButton_Play:
        m_player->resume();
        break;
    case SystemMediaTransportControlsButton_Pause:
    case SystemMediaTransportControlsButton_Stop:
        if (m_player->isPlaying() || m_player->isLoading()) {
            m_player->pause();
        }
        break;
    case SystemMediaTransportControlsButton_Next:
        m_player->skipForward();
        break;
    case SystemMediaTransportControlsButton_Previous:
        m_player->skipBackward();
        break;
    default:
        break;
    }
}

void WindowsIntegration::updateMediaControls()
{
    if (!m_native || !m_native->controls) return;
    using namespace ABI::Windows::Media;
    if (!m_player->hasSong()) {
        m_native->controls->put_PlaybackStatus(MediaPlaybackStatus_Closed);
        m_native->controls->put_IsPlayEnabled(false);
        m_native->controls->put_IsPauseEnabled(false);
        m_native->controls->put_IsNextEnabled(false);
        m_native->controls->put_IsPreviousEnabled(false);
    } else {
        m_native->controls->put_PlaybackStatus(m_player->isPlaying() ? MediaPlaybackStatus_Playing : MediaPlaybackStatus_Paused);
        m_native->controls->put_IsPlayEnabled(true);
        m_native->controls->put_IsPauseEnabled(true);
        m_native->controls->put_IsNextEnabled(m_player->canSkipForward());
        m_native->controls->put_IsPreviousEnabled(m_player->canSkipBackward());
    }
    if (m_native->controls2) {
        m_native->controls2->put_IsShuffleEnabled(m_player->isShuffleEnabled() ? TRUE : FALSE);
        MediaPlaybackAutoRepeatMode repeatMode = MediaPlaybackAutoRepeatMode_None;
        if (m_player->repeatMode() == PlaybackController::RepeatMode::All) {
            repeatMode = MediaPlaybackAutoRepeatMode_List;
        } else if (m_player->repeatMode() == PlaybackController::RepeatMode::One) {
            repeatMode = MediaPlaybackAutoRepeatMode_Track;
        }
        m_native->controls2->put_AutoRepeatMode(repeatMode);
    }
}

void WindowsIntegration::updateMediaTimeline()
{
    if (!m_native || !m_native->controls2) return;
    using namespace ABI::Windows::Media;
    using namespace ABI::Windows::Foundation;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HStringReference;

    HStringReference timelineClass(RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties);
    ComPtr<IInspectable> inspectable;
    if (FAILED(RoActivateInstance(timelineClass.Get(), &inspectable)) || !inspectable) {
        return;
    }
    ComPtr<ISystemMediaTransportControlsTimelineProperties> timeline;
    if (FAILED(inspectable.As(&timeline)) || !timeline) {
        return;
    }

    const qint64 durationTicks = m_player->hasSong() ? qMax(0, m_player->durationMs()) * 10000LL : 0;
    const qint64 positionTicks = m_player->hasSong()
        ? qBound<qint64>(0, qint64(m_player->livePositionMs()) * 10000LL, durationTicks)
        : 0;

    timeline->put_StartTime(TimeSpan{0});
    timeline->put_MinSeekTime(TimeSpan{0});
    timeline->put_EndTime(TimeSpan{durationTicks});
    timeline->put_MaxSeekTime(TimeSpan{durationTicks});
    timeline->put_Position(TimeSpan{positionTicks});

    m_native->controls2->UpdateTimelineProperties(timeline.Get());
}

void WindowsIntegration::updateMediaMetadata()
{
    if (!m_native || !m_native->controls) return;
    using namespace ABI::Windows::Media;
    using namespace ABI::Windows::Foundation;
    using namespace ABI::Windows::Storage::Streams;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HString;
    using Microsoft::WRL::Wrappers::HStringReference;

    ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
    if (FAILED(m_native->controls->get_DisplayUpdater(&updater)) || !updater) {
        return;
    }

    if (!m_player->hasSong()) {
        updater->ClearAll();
        updater->Update();
        return;
    }

    const Song song = m_player->currentSong();
    updater->put_Type(MediaPlaybackType_Music);

    ComPtr<IMusicDisplayProperties> music;
    if (SUCCEEDED(updater->get_MusicProperties(&music)) && music) {
        HString title;
        title.Set(reinterpret_cast<const wchar_t *>(song.name.utf16()), UINT32(song.name.length()));
        music->put_Title(title.Get());

        HString artist;
        artist.Set(reinterpret_cast<const wchar_t *>(song.artists.utf16()), UINT32(song.artists.length()));
        music->put_Artist(artist.Get());

        // the album title came in the interface's second version
        ComPtr<IMusicDisplayProperties2> music2;
        if (!song.albumName.isEmpty() && SUCCEEDED(music.As(&music2)) && music2) {
            HString album;
            album.Set(reinterpret_cast<const wchar_t *>(song.albumName.utf16()), UINT32(song.albumName.length()));
            music2->put_AlbumTitle(album.Get());
        }
    }

    if (song.artworkUrl.isValid()) {
        ComPtr<IUriRuntimeClassFactory> uriFactory;
        HStringReference uriClassName(RuntimeClass_Windows_Foundation_Uri);
        if (SUCCEEDED(RoGetActivationFactory(uriClassName.Get(), IID_PPV_ARGS(&uriFactory))) && uriFactory) {
            const QString urlStr = song.artworkUrl.toString();
            HString uriHStr;
            uriHStr.Set(reinterpret_cast<const wchar_t *>(urlStr.utf16()), UINT32(urlStr.length()));
            ComPtr<IUriRuntimeClass> uri;
            if (SUCCEEDED(uriFactory->CreateUri(uriHStr.Get(), &uri)) && uri) {
                ComPtr<IRandomAccessStreamReferenceStatics> streamStatics;
                HStringReference streamClassName(RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference);
                if (SUCCEEDED(RoGetActivationFactory(streamClassName.Get(), IID_PPV_ARGS(&streamStatics))) && streamStatics) {
                    ComPtr<IRandomAccessStreamReference> thumbnail;
                    if (SUCCEEDED(streamStatics->CreateFromUri(uri.Get(), &thumbnail)) && thumbnail) {
                        updater->put_Thumbnail(thumbnail.Get());
                    }
                }
            }
        }
    }

    updater->Update();
}
#else
// built without the media controls: the headers had no declarations for them
void WindowsIntegration::initializeMediaControls() {}
void WindowsIntegration::handleMediaButton(int) {}
void WindowsIntegration::updateMediaControls() {}
void WindowsIntegration::updateMediaMetadata() {}
void WindowsIntegration::updateMediaTimeline() {}
#endif

} // namespace swiftify
