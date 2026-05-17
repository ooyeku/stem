(* Pattern matching + records. Run with: ocaml main.ml *)

type employee = {
  name: string;
  role: string;
  salary: float;
}

type department = {
  name: string;
  employees: employee list;
}

let total_payroll dept =
  List.fold_left (fun acc e -> acc +. e.salary) 0.0 dept.employees

let highest_paid dept =
  match dept.employees with
  | [] -> None
  | first :: rest ->
    Some (List.fold_left
            (fun top e -> if e.salary > top.salary then e else top)
            first rest)

let categorize e =
  match e.salary with
  | s when s < 30000.0 -> "entry"
  | s when s < 70000.0 -> "mid"
  | _ -> "senior"

let () =
  let engineering = {
    name = "Engineering";
    employees = [
      { name = "Ada";    role = "Eng"; salary = 95_000.0 };
      { name = "Linus";  role = "Eng"; salary = 80_000.0 };
      { name = "Grace";  role = "Eng"; salary = 65_000.0 };
      { name = "Trainee"; role = "Eng"; salary = 25_000.0 };
    ];
  } in
  Printf.printf "%s payroll: $%.2f\n" engineering.name (total_payroll engineering);
  (match highest_paid engineering with
   | Some e -> Printf.printf "top earner: %s ($%.2f, %s)\n" e.name e.salary (categorize e)
   | None -> print_endline "no employees");
  List.iter
    (fun e -> Printf.printf "  %-8s %s\n" e.name (categorize e))
    engineering.employees
