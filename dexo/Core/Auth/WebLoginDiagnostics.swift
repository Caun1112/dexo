import Foundation
import WebKit

/// Opt-in instrumentation for every page and frame inside the login web view.
/// The script is not installed until the user enables diagnostics, and it
/// never reads request headers, request bodies, cookies, or Web Storage.
final class WebLoginDiagnostics: NSObject {
    static let handlerName = "dexoLoginDiagnostics"

    private let onEvent: (String) -> Void
    private var isInstalled = false
    private(set) var isEnabled = false

    init(onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
    }

    func register(with configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, name: Self.handlerName)
    }

    func enable(in webView: WKWebView) {
        isEnabled = true
        if !isInstalled {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
            isInstalled = true
        }
        webView.evaluateJavaScript(Self.captureScript)
    }

    func disable(in webView: WKWebView?) {
        isEnabled = false
        webView?.evaluateJavaScript("window.__dexoLoginDiagnosticsEnabled = false;")
    }

    private static func redact(_ input: String) -> String {
        let pattern = #"(?i)((?:token|api[_-]?key|password|passwd|secret|authorization|cookie|csrf|nonce|credential|session|email|username)\s*[:=]\s*)[^\s&,;]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return String(input.prefix(4_000))
        }
        let range = NSRange(input.startIndex..., in: input)
        let redacted = expression.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: "$1<redacted>"
        )
        return String(redacted.prefix(4_000))
    }

    private static let captureScript = #"""
    (function() {
        window.__dexoLoginDiagnosticsEnabled = true;
        if (window.__dexoLoginDiagnosticsInstalled) return;
        window.__dexoLoginDiagnosticsInstalled = true;

        function redact(value) {
            var text;
            function jsonReplacer(key, nestedValue) {
                if (/token|api.?key|password|passwd|secret|authorization|cookie|csrf|nonce|credential|session|email|username/i.test(key)) {
                    return '<redacted>';
                }
                return nestedValue;
            }
            try {
                if (value instanceof Error) {
                    text = value.name + ': ' + value.message;
                } else if (typeof value === 'object' && value !== null) {
                    text = JSON.stringify(value, jsonReplacer);
                } else {
                    text = String(value);
                    if (typeof value === 'string') {
                        try {
                            var parsed = JSON.parse(value);
                            if (parsed && typeof parsed === 'object') {
                                text = JSON.stringify(parsed, jsonReplacer);
                            }
                        } catch (_) {}
                    }
                }
            } catch (_) {
                text = String(value);
            }
            return text
                .replace(/([?&](?:token|api.?key|password|passwd|secret|authorization|cookie|csrf|nonce|credential|session|email|username)=)[^&\s]*/gi, '$1<redacted>')
                .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+/gi, '$1 <redacted>')
                .slice(0, 2000);
        }

        function safeURL(value) {
            try {
                var url = new URL(value, window.location.href);
                return url.origin + url.pathname;
            } catch (_) {
                return '<invalid URL>';
            }
        }

        function report(source, message) {
            if (!window.__dexoLoginDiagnosticsEnabled) return;
            try {
                window.webkit.messageHandlers.dexoLoginDiagnostics.postMessage({
                    source: String(source).slice(0, 40),
                    message: redact(message)
                });
            } catch (_) {}
        }

        function isErrorPayload(body) {
            if (!body) return false;
            try {
                var payload = JSON.parse(body);
                if (!payload || typeof payload !== 'object') return false;
                var errors = payload.errors;
                return Boolean(
                    payload.error ||
                    (Array.isArray(errors) ? errors.length : errors) ||
                    payload.success === false ||
                    payload.ok === false ||
                    payload.can_login === false
                );
            } catch (_) {
                return false;
            }
        }

        window.addEventListener('error', function(event) {
            if (event.target && event.target !== window) {
                report('Resource', 'Failed to load ' + safeURL(event.target.src || event.target.href || ''));
                return;
            }
            report(
                'JavaScript',
                (event.message || 'Unknown error') + ' at ' + safeURL(event.filename || '') + ':' +
                    (event.lineno || 0) + ':' + (event.colno || 0)
            );
        }, true);

        window.addEventListener('unhandledrejection', function(event) {
            report('Promise', event.reason || 'Unhandled rejection');
        });

        var originalConsoleError = console.error;
        console.error = function() {
            report('Console', Array.prototype.map.call(arguments, redact).join(' '));
            return originalConsoleError.apply(console, arguments);
        };

        var originalFetch = window.fetch;
        if (originalFetch) {
            window.fetch = function(input, init) {
                var method = (init && init.method) || (input && input.method) || 'GET';
                var url = safeURL((input && input.url) || input);
                return originalFetch.apply(this, arguments).then(function(response) {
                    var summary = method + ' ' + url + ' → HTTP ' + response.status + ' ' + response.statusText;
                    response.clone().text().then(function(body) {
                        if (!response.ok || isErrorPayload(body)) {
                            report('Fetch', summary + (body ? '\n' + redact(body) : ''));
                        }
                    }).catch(function() {
                        if (!response.ok) {
                            report('Fetch', summary);
                        }
                    });
                    return response;
                }).catch(function(error) {
                    report('Fetch', method + ' ' + url + ' → ' + redact(error));
                    throw error;
                });
            };
        }

        var requests = new WeakMap();
        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (!requests.has(this)) {
                this.addEventListener('loadend', function() {
                    var request = requests.get(this);
                    if (!request) return;
                    var summary = request.method + ' ' + request.url + ' → HTTP ' + this.status + ' ' + this.statusText;
                    var body = '';
                    try {
                        if (typeof this.responseText === 'string' && this.responseText) {
                            body = this.responseText;
                        }
                    } catch (_) {}
                    if (this.status > 0 && this.status < 400 && !isErrorPayload(body)) return;
                    if (body) summary += '\n' + redact(body);
                    report('XHR', summary);
                });
            }
            requests.set(this, { method: String(method || 'GET'), url: safeURL(url) });
            return originalOpen.apply(this, arguments);
        };
    })();
    """#
}

extension WebLoginDiagnostics: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isEnabled,
              message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let source = body["source"] as? String,
              let details = body["message"] as? String
        else { return }

        onEvent(Self.redact("\(source)\n\(details)"))
    }
}
