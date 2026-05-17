<?php
// Order total with discounts. Run with: php index.php

declare(strict_types=1);

interface DiscountRule {
    public function apply(float $subtotal): float;
}

final class PercentDiscount implements DiscountRule {
    public function __construct(private readonly float $percent) {}

    public function apply(float $subtotal): float {
        return $subtotal * (1 - $this->percent / 100);
    }
}

final class Cart {
    /** @var array<int, array{name: string, price: float, qty: int}> */
    private array $lines = [];

    public function add(string $name, float $price, int $qty = 1): void {
        $this->lines[] = ['name' => $name, 'price' => $price, 'qty' => $qty];
    }

    public function subtotal(): float {
        return array_reduce(
            $this->lines,
            fn(float $sum, array $line): float => $sum + $line['price'] * $line['qty'],
            0.0
        );
    }

    public function total(?DiscountRule $rule = null): float {
        $sub = $this->subtotal();
        return $rule ? $rule->apply($sub) : $sub;
    }
}

$cart = new Cart();
$cart->add('book', 12.50, 2);
$cart->add('mug',   8.00, 1);
$cart->add('pen',   1.25, 4);

$discount = new PercentDiscount(15.0);
printf("subtotal: $%.2f\n", $cart->subtotal());
printf("total:    $%.2f (15%% off)\n", $cart->total($discount));
