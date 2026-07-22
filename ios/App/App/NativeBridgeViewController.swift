import Capacitor
import UIKit
import WebKit

/// Keeps the authenticated official origin while applying iOS-specific fixes
/// before the web application starts executing.
final class NativeBridgeViewController: CAPBridgeViewController {
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        let source = #"""
        (() => {
            const nativeAmazonWorkerPath = '/sw-amazon.js';
            const nativeAmazonWorkerVersion = '2026-06-23-flac-hls-v8';
            const serviceWorkers = navigator.serviceWorker;

            if (serviceWorkers && window.isSecureContext) {
                const installAmazonWorker = async () => {
                    try {
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
                };

                // The remote app unregisters PWA workers during startup. Register after
                // that cleanup without modifying browser APIs that Turnstile validates.
                window.addEventListener('load', () => {
                    setTimeout(installAmazonWorker, 0);
                    setTimeout(installAmazonWorker, 2000);
                    setTimeout(installAmazonWorker, 5000);
                }, { once: true });
            }

            const installNativeStyle = () => {
                document.documentElement.classList.add('monochrome-native-ios');
                if (document.getElementById('monochrome-native-ios-style')) return;
                const style = document.createElement('style');
                style.id = 'monochrome-native-ios-style';
                style.textContent = `
                    @media (max-width: 430px) {
                        :root { --player-bar-height-mobile: 64px !important; }
                        html { background: #000; }
                        body { overscroll-behavior-y: none; }
                        .main-content { padding: 0 16px calc(148px + env(safe-area-inset-bottom)) !important; }
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
                        .settings-tabs {
                            display: flex !important;
                            flex-wrap: nowrap !important;
                            gap: .25rem !important;
                            max-width: 100% !important;
                            margin: 0 0 var(--spacing-lg) !important;
                            padding: 0 .2rem !important;
                            overflow-x: auto !important;
                            overflow-y: hidden !important;
                            border: 0 !important;
                            border-bottom: 1px solid var(--border) !important;
                            border-radius: 0 !important;
                            background: transparent !important;
                            -webkit-overflow-scrolling: touch;
                            scrollbar-width: none;
                        }
                        .settings-tabs::-webkit-scrollbar { display: none; }
                        .settings-tab {
                            flex: 0 0 auto !important;
                            min-width: max-content !important;
                            min-height: 38px !important;
                            padding: .5rem .55rem !important;
                            border: 0 !important;
                            border-bottom: 2px solid transparent !important;
                            border-radius: 0 !important;
                            white-space: nowrap !important;
                            font-size: .8rem !important;
                        }
                        .settings-tab.active {
                            border-bottom-color: var(--highlight) !important;
                            color: var(--foreground) !important;
                            background: transparent !important;
                            box-shadow: none !important;
                        }
                        .now-playing-bar {
                            width: calc(100% - 16px) !important;
                            left: 8px !important;
                            bottom: calc(58px + env(safe-area-inset-bottom)) !important;
                            height: 64px !important;
                            grid-template: 'track controls' 1fr / minmax(0, 1fr) auto !important;
                            gap: 6px !important;
                            padding: 7px 10px !important;
                            border-radius: 14px !important;
                            background-color: color-mix(in srgb, var(--card) 94%, transparent) !important;
                            box-shadow: 0 8px 30px rgb(0 0 0 / 38%) !important;
                        }
                        .now-playing-bar .track-info {
                            grid-area: track !important;
                            gap: 10px !important;
                            overflow: hidden !important;
                        }
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
                        .now-playing-bar .player-controls .buttons { gap: 0 !important; padding: 0 !important; }
                        .now-playing-bar .player-controls .buttons button {
                            width: 36px !important;
                            height: 40px !important;
                            min-width: 36px !important;
                            min-height: 40px !important;
                        }
                        .now-playing-bar .player-controls .buttons .play-pause-btn {
                            width: 40px !important;
                            height: 40px !important;
                            min-width: 40px !important;
                            min-height: 40px !important;
                        }
                        .now-playing-bar .play-pause-btn:empty::before {
                            content: '';
                            width: 0;
                            height: 0;
                            margin-left: 2px;
                            border-top: 6px solid transparent;
                            border-bottom: 6px solid transparent;
                            border-left: 9px solid currentcolor;
                        }
                        #download-notifications {
                            right: 10px !important;
                            bottom: calc(env(safe-area-inset-bottom) + 142px) !important;
                            left: 10px !important;
                            max-width: none !important;
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

}
