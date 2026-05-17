// Shape area dispatch. Run with: swift main.swift

import Foundation

protocol Shape {
    var name: String { get }
    func area() -> Double
}

struct Circle: Shape {
    let radius: Double
    var name: String { "circle" }
    func area() -> Double { Double.pi * radius * radius }
}

struct Rectangle: Shape {
    let width: Double
    let height: Double
    var name: String { "rectangle" }
    func area() -> Double { width * height }
}

struct Triangle: Shape {
    let base: Double
    let height: Double
    var name: String { "triangle" }
    func area() -> Double { 0.5 * base * height }
}

enum Sort {
    case ascending
    case descending
}

func summarize(_ shapes: [Shape], sortedBy order: Sort = .descending) {
    let sorted = shapes.sorted {
        order == .ascending ? $0.area() < $1.area() : $0.area() > $1.area()
    }
    for shape in sorted {
        let label = shape.name.padding(toLength: 10, withPad: " ", startingAt: 0)
        print("  \(label) \(String(format: "%8.3f", shape.area()))")
    }
    let total = shapes.reduce(0.0) { $0 + $1.area() }
    print("  total      \(String(format: "%8.3f", total))")
}

let shapes: [Shape] = [
    Circle(radius: 3),
    Rectangle(width: 4, height: 5),
    Triangle(base: 6, height: 4),
]

summarize(shapes)
