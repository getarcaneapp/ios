import SwiftUI

extension View {
    /// Push `value` into `binding` only after it stops changing for `duration`.
    /// Useful for search fields where every keystroke would otherwise re-run a
    /// filter or animation.
    func debounce<Value: Equatable>(
        _ value: Value,
        for duration: Duration,
        into binding: Binding<Value>
    ) -> some View {
        task(id: value) {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            binding.wrappedValue = value
        }
    }
}
