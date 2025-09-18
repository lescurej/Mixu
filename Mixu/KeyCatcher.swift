import SwiftUI
import AppKit

struct KeyboardCatcher: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: ((NSEvent) -> Void)? = nil

    func makeNSView(context: Context) -> KeyboardCatcherNSView {
        let view = KeyboardCatcherNSView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        return view
    }

    func updateNSView(_ nsView: KeyboardCatcherNSView, context: Context) {}
}

final class KeyboardCatcherNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // reclaim focus when clicked
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event)
    }
}

struct KeyboardManager: ViewModifier {
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: ((NSEvent) -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .background(
                KeyboardCatcher(onKeyDown: onKeyDown, onKeyUp: onKeyUp)
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // ensure it fills space
            )
    }
}

extension View {
    func onKeyDown(_ onKeyDown: @escaping (NSEvent) -> Void,
                   onKeyUp: ((NSEvent) -> Void)? = nil) -> some View {
        self.modifier(KeyboardManager(onKeyDown: onKeyDown, onKeyUp: onKeyUp))
    }
}
