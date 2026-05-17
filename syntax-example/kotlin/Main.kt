// Sealed Result type. Run with: kotlinc Main.kt -include-runtime -d main.jar && java -jar main.jar

sealed class Result<out T> {
    data class Ok<T>(val value: T) : Result<T>()
    data class Err(val message: String) : Result<Nothing>()
}

inline fun <T, R> Result<T>.map(transform: (T) -> R): Result<R> = when (this) {
    is Result.Ok -> Result.Ok(transform(value))
    is Result.Err -> this
}

fun parseAge(text: String): Result<Int> {
    val n = text.toIntOrNull() ?: return Result.Err("not a number: $text")
    return if (n in 0..150) Result.Ok(n) else Result.Err("out of range: $n")
}

data class Person(val name: String, val age: Int) {
    val category: String = when {
        age < 13 -> "child"
        age < 20 -> "teen"
        age < 65 -> "adult"
        else -> "senior"
    }
}

fun main() {
    val inputs = listOf("42", "-5", "abc", "200", "17")
    val people = inputs
        .map { parseAge(it).map { age -> Person("user_$it", age) } }

    for ((i, result) in people.withIndex()) {
        when (result) {
            is Result.Ok -> println("[$i] ok  -> ${result.value} (${result.value.category})")
            is Result.Err -> println("[$i] err -> ${result.message}")
        }
    }
}
