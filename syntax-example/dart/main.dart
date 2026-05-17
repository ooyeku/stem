// Async stream demo. Run with: dart main.dart

class Temperature {
  final String city;
  final double celsius;
  final DateTime at;

  Temperature(this.city, this.celsius, this.at);

  double get fahrenheit => celsius * 9 / 5 + 32;

  @override
  String toString() =>
      '$city: ${celsius.toStringAsFixed(1)}°C / ${fahrenheit.toStringAsFixed(1)}°F';
}

Stream<Temperature> readings(List<String> cities) async* {
  for (final city in cities) {
    await Future.delayed(Duration(milliseconds: 50));
    final base = city.codeUnits.fold<int>(0, (a, b) => a + b) % 30;
    yield Temperature(city, base.toDouble() - 5, DateTime.now());
  }
}

Future<void> main() async {
  final cities = ['Tokyo', 'Reykjavik', 'Lagos', 'Berlin'];
  var hottest = Temperature('', -double.infinity, DateTime.now());

  await for (final t in readings(cities)) {
    print(t);
    if (t.celsius > hottest.celsius) hottest = t;
  }

  print('---');
  print('hottest: ${hottest.city} (${hottest.celsius.toStringAsFixed(1)}°C)');
}
