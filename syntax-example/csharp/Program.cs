// Async data fetcher. Run with: dotnet run

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace YapDemo;

public record User(int Id, string Name, decimal Balance);

public class UserService
{
    private readonly Dictionary<int, User> _store = new()
    {
        [1] = new User(1, "Alice", 100.50m),
        [2] = new User(2, "Bob",   42.00m),
        [3] = new User(3, "Carol", 999.99m),
    };

    public async Task<User?> GetAsync(int id)
    {
        await Task.Delay(5);
        return _store.TryGetValue(id, out var u) ? u : null;
    }

    public async IAsyncEnumerable<User> RichUsersAsync(decimal threshold)
    {
        foreach (var user in _store.Values)
        {
            await Task.Delay(2);
            if (user.Balance >= threshold) yield return user;
        }
    }
}

public static class Program
{
    public static async Task Main()
    {
        var svc = new UserService();
        var alice = await svc.GetAsync(1);
        Console.WriteLine($"got: {alice}");

        var rich = new List<User>();
        await foreach (var u in svc.RichUsersAsync(50m)) rich.Add(u);

        Console.WriteLine($"{rich.Count} rich users:");
        rich.OrderByDescending(u => u.Balance).ToList()
            .ForEach(u => Console.WriteLine($"  {u.Name,-8} ${u.Balance}"));
    }
}
