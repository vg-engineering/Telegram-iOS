import Foundation
import UIKit
import Display
import WebKit
import SwiftSignalKit

private let findActiveElementY = """
function getOffset(el) {
    const rect = el.getBoundingClientRect();
    return {
        left: rect.left + window.scrollX,
        top: rect.top + window.scrollY
    };
}
getOffset(document.activeElement).top;
"""

private class WeakGameScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private let f: (WKScriptMessage) -> ()
    
    init(_ f: @escaping (WKScriptMessage) -> ()) {
        self.f = f
        
        super.init()
    }
    
    func userContentController(_ controller: WKUserContentController, didReceive scriptMessage: WKScriptMessage) {
        self.f(scriptMessage)
    }
}

private class WebViewTouchGestureRecognizer: UITapGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .began
    }
}

private let eventProxySource = "var TelegramWebviewProxyProto = function() {}; " +
    "TelegramWebviewProxyProto.prototype.postEvent = function(eventName, eventData) { " +
    "window.webkit.messageHandlers.performAction.postMessage({'eventName': eventName, 'eventData': eventData}); " +
    "}; " +
"var TelegramWebviewProxy = new TelegramWebviewProxyProto();"

private let selectionSource = "var css = '*{-webkit-touch-callout:none;} :not(input):not(textarea):not([\"contenteditable\"=\"true\"]){-webkit-user-select:none;}';"
        + " var head = document.head || document.getElementsByTagName('head')[0];"
        + " var style = document.createElement('style'); style.type = 'text/css';" +
        " style.appendChild(document.createTextNode(css)); head.appendChild(style);"

private let videoSource = """
function disableWebkitEnterFullscreen(videoElement) {
  if (videoElement && videoElement.webkitEnterFullscreen) {
    Object.defineProperty(videoElement, 'webkitEnterFullscreen', {
      value: undefined
    });
  }
}

function disableFullscreenOnExistingVideos() {
  document.querySelectorAll('video').forEach(disableWebkitEnterFullscreen);
}

function handleMutations(mutations) {
  mutations.forEach((mutation) => {
    if (mutation.addedNodes && mutation.addedNodes.length > 0) {
      mutation.addedNodes.forEach((newNode) => {
        if (newNode.tagName === 'VIDEO') {
          disableWebkitEnterFullscreen(newNode);
        }
        if (newNode.querySelectorAll) {
          newNode.querySelectorAll('video').forEach(disableWebkitEnterFullscreen);
        }
      });
    }
  });
}

disableFullscreenOnExistingVideos();

const observer = new MutationObserver(handleMutations);

observer.observe(document.body, {
  childList: true,
  subtree: true
});

function disconnectObserver() {
  observer.disconnect();
}
"""

final class WebAppWebView: WKWebView {
    var handleScriptMessage: (WKScriptMessage) -> Void = { _ in }
    
    init() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
                           
        var handleScriptMessageImpl: ((WKScriptMessage) -> Void)?
        let eventProxyScript = WKUserScript(source: eventProxySource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(eventProxyScript)
        contentController.add(WeakGameScriptMessageHandler { message in
            handleScriptMessageImpl?(message)
        }, name: "performAction")
        
        let selectionScript = WKUserScript(source: selectionSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(selectionScript)
        
        let videoScript = WKUserScript(source: videoSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(videoScript)
        
        configuration.userContentController = contentController
        
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        if #available(iOS 10.0, *) {
            configuration.mediaTypesRequiringUserActionForPlayback = .audio
        } else {
            configuration.mediaPlaybackRequiresUserAction = true
        }
        
        super.init(frame: CGRect(), configuration: configuration)
        
        self.disablesInteractiveKeyboardGestureRecognizer = true
        
        self.isOpaque = false
        self.backgroundColor = .clear
        if #available(iOS 9.0, *) {
            self.allowsLinkPreview = false
        }
        if #available(iOS 11.0, *) {
            self.scrollView.contentInsetAdjustmentBehavior = .never
        }
        self.interactiveTransitionGestureRecognizerTest = { point -> Bool in
            return point.x > 30.0
        }
        self.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) {
            self.isInspectable = true
        } 
        
        handleScriptMessageImpl = { [weak self] message in
            if let strongSelf = self {
                strongSelf.handleScriptMessage(message)
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        if #available(iOS 11.0, *) {
            let webScrollView = self.subviews.compactMap { $0 as? UIScrollView }.first
            Queue.mainQueue().after(0.1, {
                let contentView = webScrollView?.subviews.first(where: { $0.interactions.count > 1 })
                guard let dragInteraction = (contentView?.interactions.compactMap { $0 as? UIDragInteraction }.first) else {
                    return
                }
                contentView?.removeInteraction(dragInteraction)
            })
            
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
        }
    }
    
    func sendEvent(name: String, data: String?) {
        let script = "window.TelegramGameProxy.receiveEvent(\"\(name)\", \(data ?? "null"))"
        self.evaluateJavaScript(script, completionHandler: { _, _ in
        })
    }
        
    func updateMetrics(height: CGFloat, isExpanded: Bool, isStable: Bool, transition: ContainedViewLayoutTransition) {
        let data = "{height:\(height), is_expanded:\(isExpanded ? "true" : "false"), is_state_stable:\(isStable ? "true" : "false")}"
        self.sendEvent(name: "viewport_changed", data: data)
    }
    
    var lastTouchTimestamp: Double?
    private(set) var didTouchOnce = false
    var onFirstTouch: () -> Void = {}
    
    func scrollToActiveElement(layout: ContainerViewLayout, completion: @escaping (CGPoint) -> Void, transition: ContainedViewLayoutTransition) {
        self.evaluateJavaScript(findActiveElementY, completionHandler: { result, _ in
            if let result = result as? CGFloat {
                Queue.mainQueue().async {
                    let convertedY = result - self.scrollView.contentOffset.y
                    let viewportHeight = self.frame.height - (layout.inputHeight ?? 0.0) + 26.0
                    if convertedY < 0.0 || (convertedY + 44.0) > viewportHeight {
                        let targetOffset: CGFloat
                        if convertedY < 0.0 {
                            targetOffset = max(0.0, result - 36.0)
                        } else {
                            targetOffset = max(0.0, result + 60.0 - viewportHeight)
                        }
                        let contentOffset = CGPoint(x: 0.0, y: targetOffset)
                        completion(contentOffset)
                        transition.animateView({
                            self.scrollView.contentOffset = contentOffset
                        })
                    }
                }
            }
        })
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        self.lastTouchTimestamp = CACurrentMediaTime()
        if result != nil && !self.didTouchOnce {
            self.didTouchOnce = true
            self.onFirstTouch()
        }
        return result
    }
    
    override var inputAccessoryView: UIView? {
        return nil
    }
}
