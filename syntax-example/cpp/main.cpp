// RAII bank account. Build with: c++ -std=c++20 main.cpp -o main && ./main

#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

class Account {
public:
    Account(std::string owner, double initial)
        : owner_(std::move(owner)), balance_(initial) {
        if (initial < 0) throw std::invalid_argument("negative initial balance");
    }

    void deposit(double amount) {
        if (amount <= 0) throw std::invalid_argument("non-positive deposit");
        balance_ += amount;
    }

    void withdraw(double amount) {
        if (amount > balance_) throw std::runtime_error("insufficient funds");
        balance_ -= amount;
    }

    [[nodiscard]] double balance() const noexcept { return balance_; }
    [[nodiscard]] const std::string& owner() const noexcept { return owner_; }

private:
    std::string owner_;
    double balance_;
};

int main() {
    std::vector<std::unique_ptr<Account>> accounts;
    accounts.emplace_back(std::make_unique<Account>("Alice", 100.0));
    accounts.emplace_back(std::make_unique<Account>("Bob", 250.0));

    try {
        accounts[0]->deposit(50.0);
        accounts[1]->withdraw(75.0);
        accounts[0]->withdraw(9999.0);  // throws
    } catch (const std::exception& e) {
        std::cerr << "error: " << e.what() << '\n';
    }

    for (const auto& acc : accounts) {
        std::cout << acc->owner() << ": $" << acc->balance() << '\n';
    }
    return 0;
}
