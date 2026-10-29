// LocalState.swift - same as SwiftUI's @State, but usable when building with only
// Apple's Command Line Tools (which lack the SwiftUI macro plugin that @State now needs).
import SwiftUI

@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private var storage: State<Value>
    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
