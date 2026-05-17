// Inventory with streams. Compile: javac Main.java && java Main

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

public class Main {

    record Item(String name, String category, double price, int qty) {
        double total() { return price * qty; }
    }

    public static void main(String[] args) {
        List<Item> items = List.of(
            new Item("notebook",  "office", 4.50, 12),
            new Item("pen",       "office", 1.25, 50),
            new Item("monitor",   "tech",   220.00, 3),
            new Item("keyboard",  "tech",   75.00, 5),
            new Item("paperclip", "office", 0.10, 200)
        );

        Map<String, Double> byCategory = items.stream()
            .collect(Collectors.groupingBy(
                Item::category,
                Collectors.summingDouble(Item::total)
            ));

        byCategory.forEach((cat, total) ->
            System.out.printf("%-10s $%.2f%n", cat, total)
        );

        items.stream()
            .filter(i -> i.qty() < 10)
            .map(Item::name)
            .forEach(name -> System.out.println("low stock: " + name));
    }
}
