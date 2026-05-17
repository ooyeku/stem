// Generic stack with traits. Run with: rustc main.rs && ./main

use std::fmt::Debug;

#[derive(Debug)]
struct Stack<T: Debug> {
    items: Vec<T>,
}

impl<T: Debug> Stack<T> {
    fn new() -> Self {
        Self { items: Vec::new() }
    }

    fn push(&mut self, item: T) {
        self.items.push(item);
    }

    fn pop(&mut self) -> Option<T> {
        self.items.pop()
    }

    fn peek(&self) -> Option<&T> {
        self.items.last()
    }

    fn len(&self) -> usize {
        self.items.len()
    }
}

trait Describe {
    fn describe(&self) -> String;
}

impl<T: Debug> Describe for Stack<T> {
    fn describe(&self) -> String {
        format!("Stack({} items, top={:?})", self.len(), self.peek())
    }
}

fn main() {
    let mut stack: Stack<i32> = Stack::new();
    for n in 1..=5 {
        stack.push(n * n);
    }
    println!("{}", stack.describe());

    while let Some(v) = stack.pop() {
        print!("{} ", v);
    }
    println!();
}
