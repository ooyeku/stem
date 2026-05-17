// Case classes + pattern matching. Run with: scala Main.scala

object Main {

  sealed trait Json
  case object JsonNull extends Json
  case class JsonBool(value: Boolean) extends Json
  case class JsonNum(value: Double) extends Json
  case class JsonStr(value: String) extends Json
  case class JsonArr(items: List[Json]) extends Json
  case class JsonObj(fields: Map[String, Json]) extends Json

  def render(j: Json, indent: Int = 0): String = {
    val pad = "  " * indent
    j match {
      case JsonNull       => "null"
      case JsonBool(b)    => b.toString
      case JsonNum(n)     => if (n == n.toLong) n.toLong.toString else n.toString
      case JsonStr(s)     => s"\"$s\""
      case JsonArr(xs)    =>
        xs.map(render(_, indent + 1)).mkString("[\n" + pad + "  ", ",\n" + pad + "  ", "\n" + pad + "]")
      case JsonObj(m)     =>
        m.map { case (k, v) => s"$pad  \"$k\": ${render(v, indent + 1)}" }
         .mkString("{\n", ",\n", s"\n$pad}")
    }
  }

  def main(args: Array[String]): Unit = {
    val sample = JsonObj(Map(
      "name"    -> JsonStr("stem"),
      "stars"   -> JsonNum(42),
      "active"  -> JsonBool(true),
      "tags"    -> JsonArr(List(JsonStr("zig"), JsonStr("editor"))),
      "license" -> JsonNull,
    ))

    println(render(sample))
  }
}
