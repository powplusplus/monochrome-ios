import Capacitor
import UIKit
import WebKit

/// Keeps the authenticated official origin while applying iOS-specific fixes
/// before the web application starts executing.
final class NativeBridgeViewController: CAPBridgeViewController {
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.limitsNavigationsToAppBoundDomains = true
        let bundledStylesheet = Self.loadBundledStylesheet()
        let bundledStylesheetLiteral = Self.javascriptStringLiteral(bundledStylesheet)
        let source = #"""
        (() => {
            const nativeAmazonWorkerPath = '/sw-amazon.js';
            const nativeAmazonWorkerVersion = '2026-06-23-flac-hls-v8';
            const serviceWorkers = navigator.serviceWorker;

            if (serviceWorkers && window.isSecureContext) {
                const getRegistrations = serviceWorkers.getRegistrations.bind(serviceWorkers);

                // The web app removes root-scope PWA registrations in a native shell.
                // Keep that cleanup from racing the decryption-only replacement below.
                serviceWorkers.getRegistrations = async () => {
                    const registrations = await getRegistrations();
                    const rootScope = new URL('/', window.location.origin).href;
                    return registrations.filter((registration) => registration.scope !== rootScope);
                };

                window.__MONOCHROME_NATIVE_AMAZON_SW__ = (async () => {
                    try {
                        const registrations = await getRegistrations();
                        await Promise.all(registrations.map((registration) => {
                            const worker = registration.active || registration.waiting || registration.installing;
                            if (worker?.scriptURL) {
                                try {
                                    if (new URL(worker.scriptURL).pathname === nativeAmazonWorkerPath) return false;
                                } catch {}
                            }
                            return registration.unregister();
                        }));

                        const workerURL = `${nativeAmazonWorkerPath}?amazon-sw=${nativeAmazonWorkerVersion}`;
                        const registration = await serviceWorkers.register(workerURL, {
                            scope: '/',
                            updateViaCache: 'none'
                        });
                        await registration.update().catch(() => {});
                        console.log('[Amazon SW Decrypter] Native worker ready', {
                            scope: registration.scope,
                            controlled: !!serviceWorkers.controller
                        });
                        return registration;
                    } catch (error) {
                        console.warn('[Amazon SW Decrypter] Native worker registration failed', error);
                        return null;
                    }
                })();
            }

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
                style.textContent = \#(bundledStylesheetLiteral) + `
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

            const applyAppleMusicTheme = () => {
                localStorage.setItem('monochrome-theme', 'apple-music');
                document.documentElement.setAttribute('data-theme', 'apple-music');
                document.querySelectorAll('#theme-picker .theme-option').forEach((item) => {
                    item.classList.toggle('active', item.dataset.theme === 'apple-music');
                });
                document.getElementById('custom-theme-editor')?.classList.remove('show');
                window.dispatchEvent(new CustomEvent('theme-changed', { detail: { theme: 'apple-music' } }));
            };

            const installAppleMusicOption = () => {
                const picker = document.getElementById('theme-picker');
                if (!picker) return;

                let option = picker.querySelector('[data-theme="apple-music"]');
                if (!option) {
                    option = document.createElement('div');
                    option.className = 'theme-option apple-music-theme-option';
                    option.dataset.theme = 'apple-music';
                    option.setAttribute('role', 'button');
                    option.setAttribute('tabindex', '0');
                    option.textContent = 'Apple Music';

                    const systemOption = picker.querySelector('[data-theme="system"]');
                    if (systemOption) systemOption.insertAdjacentElement('afterend', option);
                    else picker.prepend(option);
                }

                if (option.dataset.nativeAppleMusicBound !== 'true') {
                    option.dataset.nativeAppleMusicBound = 'true';
                    option.addEventListener('click', applyAppleMusicTheme);
                    option.addEventListener('keydown', (event) => {
                        if (event.key === 'Enter' || event.key === ' ') {
                            event.preventDefault();
                            applyAppleMusicTheme();
                        }
                    });
                }

                if (localStorage.getItem('monochrome-theme') === 'apple-music') {
                    document.documentElement.setAttribute('data-theme', 'apple-music');
                    picker.querySelectorAll('.theme-option').forEach((item) => {
                        item.classList.toggle('active', item === option);
                    });
                }
            };

            installNativeStyle();
            const syncNativeUI = () => {
                installNativeStyle();
                installAppleMusicOption();
            };

            let syncQueued = false;
            const queueNativeUISync = () => {
                if (syncQueued) return;
                syncQueued = true;
                requestAnimationFrame(() => {
                    syncQueued = false;
                    syncNativeUI();
                });
            };

            document.addEventListener('DOMContentLoaded', syncNativeUI);
            window.addEventListener('popstate', queueNativeUISync);
            window.addEventListener('hashchange', queueNativeUISync);
            new MutationObserver(queueNativeUISync).observe(document.documentElement, {
                childList: true,
                subtree: true
            });
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
