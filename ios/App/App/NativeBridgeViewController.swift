import Capacitor
import UIKit
import WebKit

/// Keeps the authenticated official origin while applying iOS-specific fixes
/// before the web application starts executing.
final class NativeBridgeViewController: CAPBridgeViewController {
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        let bundledStylesheet = Self.loadBundledStylesheet()
        let bundledStylesheetLiteral = Self.javascriptStringLiteral(bundledStylesheet)
        let source = #"""
        (() => {
            const originalArrayFrom = Array.from;
            let bypassedPlayerImageGate = false;
            Array.from = function(value, ...argumentsList) {
                if (!bypassedPlayerImageGate && value === document.images) {
                    bypassedPlayerImageGate = true;
                    return [];
                }
                return originalArrayFrom.call(Array, value, ...argumentsList);
            };

            const installNativeStyle = () => {
                document.documentElement.classList.add('monochrome-native-ios');
                if (document.getElementById('monochrome-native-ios-style')) return;
                const style = document.createElement('style');
                style.id = 'monochrome-native-ios-style';
                style.textContent = #(bundledStylesheetLiteral) + `
                    @media (max-width: 430px) {
                        :root { --player-bar-height-mobile: 68px !important; }
                        html { background: #000; }
                        body { overscroll-behavior-y: none; }
                        .main-content { padding: 0 16px calc(92px + env(safe-area-inset-bottom)) !important; }
                        .main-header {
                            position: sticky !important;
                            top: 0 !important;
                            z-index: 100 !important;
                            min-height: calc(60px + env(safe-area-inset-top));
                            margin: 0 -16px 12px !important;
                            padding: env(safe-area-inset-top) 16px 8px !important;
                            background: color-mix(in srgb, var(--background) 88%, transparent) !important;
                            -webkit-backdrop-filter: saturate(180%) blur(20px);
                            backdrop-filter: saturate(180%) blur(20px);
                            border-bottom: 1px solid color-mix(in srgb, var(--border) 70%, transparent);
                        }
                        .hamburger-menu, .header-account-control {
                            width: 40px !important;
                            height: 40px !important;
                            flex: 0 0 40px !important;
                        }
                        .search-bar { height: 40px !important; border-radius: 12px !important; }
                        .home-header-tabs {
                            margin-inline: -16px !important;
                            padding-inline: 16px !important;
                            overflow-x: auto !important;
                            scrollbar-width: none;
                        }
                        .home-header-tabs::-webkit-scrollbar { display: none; }
                        .card-grid {
                            grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
                            gap: 16px 12px !important;
                        }
                        .now-playing-bar {
                            width: calc(100% - 16px) !important;
                            left: 8px !important;
                            bottom: calc(8px + env(safe-area-inset-bottom)) !important;
                            height: 68px !important;
                            grid-template: 'track controls' 1fr / minmax(0, 1fr) auto !important;
                            gap: 8px !important;
                            padding: 9px 8px !important;
                            border-radius: 15px !important;
                            background-color: color-mix(in srgb, var(--card) 94%, transparent) !important;
                            box-shadow: 0 8px 30px rgb(0 0 0 / 38%) !important;
                        }
                        .now-playing-bar .track-info { grid-area: track !important; }
                        .now-playing-bar .track-info .cover {
                            width: 48px !important;
                            height: 48px !important;
                            border-radius: 9px !important;
                        }
                        .now-playing-bar .track-info .details .title {
                            font-size: .92rem !important;
                            font-weight: 600 !important;
                        }
                        .now-playing-bar .track-info .details .album,
                        .now-playing-bar .player-controls .progress-container,
                        .now-playing-bar .volume-controls,
                        .now-playing-bar #shuffle-btn,
                        .now-playing-bar #prev-btn,
                        .now-playing-bar #repeat-btn { display: none !important; }
                        .now-playing-bar .player-controls {
                            grid-area: controls !important;
                            width: auto !important;
                            padding: 0 !important;
                        }
                        .now-playing-bar .player-controls .buttons { gap: 2px !important; padding: 0 !important; }
                        .now-playing-bar .player-controls .buttons button {
                            width: 40px !important;
                            height: 48px !important;
                            min-width: 40px !important;
                            min-height: 48px !important;
                        }
                        .now-playing-bar .player-controls .buttons .play-pause-btn {
                            width: 44px !important;
                            height: 48px !important;
                        }
                    }
                `;
                (document.head || document.documentElement).appendChild(style);
            };

            const installAppleMusicOption = () => {
                const picker = document.getElementById('theme-picker');
                if (!picker || picker.querySelector('[data-theme="apple-music"]')) return;

                const option = document.createElement('div');
                option.className = 'theme-option';
                option.dataset.theme = 'apple-music';
                option.textContent = 'Apple Music';

                const darkOption = picker.querySelector('[data-theme="dark"]');
                if (darkOption) darkOption.insertAdjacentElement('afterend', option);
                else picker.appendChild(option);

                if (localStorage.getItem('monochrome-theme') === 'apple-music') {
                    picker.querySelectorAll('.theme-option').forEach((item) => item.classList.remove('active'));
                    option.classList.add('active');
                    document.documentElement.setAttribute('data-theme', 'apple-music');
                }

                option.addEventListener('click', () => {
                    picker.querySelectorAll('.theme-option').forEach((item) => item.classList.remove('active'));
                    option.classList.add('active');
                    document.getElementById('custom-theme-editor')?.classList.remove('show');
                    localStorage.setItem('monochrome-theme', 'apple-music');
                    document.documentElement.setAttribute('data-theme', 'apple-music');
                    window.dispatchEvent(new CustomEvent('theme-changed', { detail: { theme: 'apple-music' } }));
                });
            };

            installNativeStyle();
            document.addEventListener('DOMContentLoaded', () => {
                installNativeStyle();
                installAppleMusicOption();
            }, { once: true });
        })();
        """#

        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        return super.webView(with: frame, configuration: configuration)
    }

    private static func loadBundledStylesheet() -> String {
        guard let assetsURL = Bundle.main.resourceURL?
            .appendingPathComponent("public", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: assetsURL,
                  includingPropertiesForKeys: nil
              ),
              let stylesheetURL = files.first(where: {
                  $0.pathExtension == "css" && $0.lastPathComponent.hasPrefix("index-")
              }),
              let stylesheet = try? String(contentsOf: stylesheetURL, encoding: .utf8) else {
            return ""
        }
        return stylesheet
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
