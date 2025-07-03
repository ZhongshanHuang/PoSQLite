import Foundation

final class Recyclable<Value> {
    typealias OnRecycled = () -> Void
    final let rawValue: Value
    let onRecycled: OnRecycled?
    
    init(_ rawValue: Value, onRecycled: OnRecycled? = nil) {
        self.rawValue = rawValue
        self.onRecycled = onRecycled
    }
    
    deinit {
        onRecycled?()
    }
}
