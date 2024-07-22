import decode
import gladvent/internal/cmd.{Ending, Endless}
import gladvent/internal/input
import gladvent/internal/parse.{type Day}
import gladvent/internal/runners
import gladvent/internal/util
import gleam
import gleam/dict as map
import gleam/dynamic.{type Dynamic}
import gleam/erlang
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/package_interface
import gleam/result
import gleam/string
import glint
import simplifile
import snag.{type Result, type Snag}
import spinner

type AsyncResult =
  gleam.Result(RunResult, String)

type RunErr {
  FailedToReadInput(String)
  FailedToParseInput(String)
  FailedToGetRunner(snag.Snag)
  Unregistered(Day)
  Other(String)
}

type RunResult =
  gleam.Result(#(SolveResult, SolveResult), RunErr)

type SolveErr {
  Undef
  RunFailed(String)
}

type SolveResult =
  gleam.Result(Dynamic, SolveErr)

fn run_err_to_snag(err: RunErr) -> Snag {
  case err {
    Unregistered(day) ->
      snag.new("day" <> " " <> int.to_string(day) <> " " <> "unregistered")
    FailedToReadInput(input_path) ->
      snag.new("failed to read input file: " <> input_path)
    FailedToParseInput(err) -> snag.new("failed to parse input: " <> err)
    FailedToGetRunner(s) -> snag.layer(s, "failed to get runner")
    Other(s) -> snag.new(s)
  }
}

type Direction {
  // Leading
  // Trailing
  Both
}

fn string_trim(s: String, dir: Direction, sub: String) -> String {
  do_trim(s, dir, charlist.from_string(sub))
}

@external(erlang, "string", "trim")
fn do_trim(a: String, b: Direction, c: Charlist) -> String

fn do(
  year: Int,
  day: Day,
  package: package_interface.Package,
  allow_crash: Bool,
  input_kind: input.Kind,
) -> RunResult {
  use #(pt_1, pt_2, parse) <- result.try(
    runners.get_day(package, year, day)
    |> result.map_error(FailedToGetRunner),
  )

  let input_path = input.get_file_path(year, day, input_kind)

  use input <- result.try(
    input_path
    |> simplifile.read()
    |> result.map(string_trim(_, Both, "\n"))
    |> result.replace_error(FailedToReadInput(input_path)),
  )

  let parse = option.unwrap(parse, dynamic.from)

  case allow_crash {
    True -> {
      let input = parse(input)
      Ok(#(Ok(pt_1(input)), Ok(pt_2(input))))
    }
    False -> {
      use input <- result.try(
        fn() { parse(input) }
        |> erlang.rescue
        |> result.map_error(crash_to_string)
        |> result.map_error(FailedToParseInput),
      )
      let pt_1 =
        fn() { pt_1(input) }
        |> erlang.rescue
        |> result.map_error(crash_to_solve_err)
      let pt_2 =
        fn() { pt_2(input) }
        |> erlang.rescue
        |> result.map_error(crash_to_solve_err)
      Ok(#(pt_1, pt_2))
    }
  }
}

fn crash_to_dyn(err: erlang.Crash) -> dynamic.Dynamic {
  case err {
    erlang.Errored(dyn) | erlang.Exited(dyn) | erlang.Thrown(dyn) -> dyn
  }
}

type GleamErr {
  GleamErr(
    gleam_error: atom.Atom,
    module: String,
    function: String,
    line: Int,
    message: String,
    value: Option(Dynamic),
  )
}

fn decode_gleam_err(dyn: dynamic.Dynamic) {
  decode.into({
    use gleam_error <- decode.parameter
    use module <- decode.parameter
    use function <- decode.parameter
    use line <- decode.parameter
    use message <- decode.parameter
    use value <- decode.parameter
    GleamErr(gleam_error, module, function, line, message, value)
  })
  |> decode.field(atom.create_from_string("gleam_error"), {
    use dyn <- decode.then(decode.dynamic)
    case atom.from_dynamic(dyn) {
      Ok(a) -> decode.into(a)
      Error(e) ->
        decode.fail("failed to decode gleam error: " <> string.inspect(e))
    }
  })
  |> decode.field(atom.create_from_string("module"), decode.string)
  |> decode.field(atom.create_from_string("function"), decode.string)
  |> decode.field(atom.create_from_string("line"), decode.int)
  |> decode.field(atom.create_from_string("message"), decode.string)
  |> decode.field(
    atom.create_from_string("value"),
    decode.optional(decode.dynamic),
  )
  |> decode.from(dyn)
}

import gleam/io

fn gleam_err_to_string(g: GleamErr) -> String {
  string.join(
    [
      "error:",
      atom.to_string(g.gleam_error),
      "-",
      g.message,
      "in module",
      g.module,
      "in function",
      g.function,
      "at line",
      int.to_string(g.line),
      g.value
        |> option.map(fn(val) { "with value " <> string.inspect(val) })
        |> option.unwrap(""),
    ],
    " ",
  )
}

fn crash_to_string(err: erlang.Crash) -> String {
  crash_to_dyn(err)
  |> decode_gleam_err()
  |> result.map(gleam_err_to_string)
  |> result.lazy_unwrap(fn() {
    "run failed for some reason: " <> string.inspect(err)
  })
}

fn crash_to_solve_err(err: erlang.Crash) -> SolveErr {
  err
  |> crash_to_string
  |> RunFailed
}

fn solve_err_to_string(solve_err: SolveErr) -> String {
  case solve_err {
    Undef -> "function undefined"
    RunFailed(s) -> s
  }
}

fn solve_res_to_string(res: SolveResult) -> String {
  case res {
    Ok(res) -> string.inspect(res)
    Error(err) -> solve_err_to_string(err)
  }
}

import gleam/pair

fn collect_async(year: Int, x: #(Day, AsyncResult)) -> String {
  x
  |> pair.map_second(result.map_error(_, Other))
  |> pair.map_second(result.flatten)
  |> collect(year, _)
}

fn collect(year: Int, x: #(Day, RunResult)) -> String {
  let day = int.to_string(x.0)

  case x.1 {
    Ok(#(res_1, res_2)) ->
      "Ran "
      <> int.to_string(year)
      <> " day "
      <> day
      <> ":\n"
      <> "  Part 1: "
      <> solve_res_to_string(res_1)
      <> "\n"
      <> "  Part 2: "
      <> solve_res_to_string(res_2)

    Error(err) ->
      err
      |> run_err_to_snag
      |> snag.layer("Failed to run " <> int.to_string(year) <> " day " <> day)
      |> snag.pretty_print()
  }
}

// ----- CLI -----

pub fn timeout_flag() {
  use i <- glint.flag_constraint(
    glint.int_flag("timeout")
    |> glint.flag_help("Run with specified timeout"),
  )

  case i > 0 {
    True -> Ok(i)
    False -> snag.error("timeout value must greater than zero")
  }
}

pub fn allow_crash_flag() {
  glint.bool_flag("allow-crash")
  |> glint.flag_default(False)
  |> glint.flag_help("Don't catch exceptions thrown by runners")
}

pub fn run_command() -> glint.Command(Result(List(String))) {
  use <- glint.command_help("Run the specified days")
  use <- glint.unnamed_args(glint.MinArgs(1))
  use example_flag <- glint.flag(
    glint.bool_flag("example")
    |> glint.flag_default(False)
    |> glint.flag_help(
      "Run solutions against example inputs (found at input/<year>/<day>.example.txt)",
    ),
  )
  use _, args, flags <- glint.command()
  use days <- result.then(parse.days(args))
  let assert Ok(year) = glint.get_flag(flags, cmd.year_flag())
  let assert Ok(allow_crash) = glint.get_flag(flags, allow_crash_flag())
  let assert Ok(use_example) = case example_flag(flags) {
    Error(a) -> Error(a)
    Ok(True) -> Ok(input.Example)
    _ -> Ok(input.Puzzle)
  }

  let spinner =
    spinner.new(
      "running days "
      <> string.join(args, ", ")
      <> " in "
      <> int.to_string(year),
    )
    |> spinner.start()

  use <- util.defer(do: fn() { spinner.stop(spinner) })

  let timing =
    glint.get_flag(flags, timeout_flag())
    |> result.map(Ending)
    |> result.unwrap(Endless)

  use package <- result.map(
    runners.pkg_interface()
    |> snag.context("failed to generate package interface"),
  )

  days
  |> cmd.exec(
    timing,
    do(year, _, package, allow_crash, use_example),
    collect_async(year, _),
  )
}

pub fn run_all_command() -> glint.Command(Result(List(String))) {
  use <- glint.command_help("Run all registered days")
  use <- glint.unnamed_args(glint.EqArgs(0))
  use _, _, flags <- glint.command()

  let assert Ok(year) = glint.get_flag(flags, cmd.year_flag())
  let assert Ok(allow_crash) = glint.get_flag(flags, allow_crash_flag())

  let spinner =
    spinner.new("running all days in " <> int.to_string(year))
    |> spinner.start()

  use <- util.defer(do: fn() { spinner.stop(spinner) })

  let timing =
    glint.get_flag(flags, timeout_flag())
    |> result.map(Ending)
    |> result.unwrap(Endless)

  use package <- result.map(
    runners.pkg_interface()
    |> snag.context("failed to generate package interface"),
  )

  package.modules
  |> map.keys
  |> list.filter_map(fn(k) {
    use day <- result.try(string.split_once(
      k,
      "aoc_" <> int.to_string(year) <> "/day_",
    ))
    day.1
    |> parse.day
    |> result.replace_error(Nil)
  })
  |> list.sort(int.compare)
  |> cmd.exec(
    timing,
    do(year, _, package, allow_crash, input.Puzzle),
    collect_async(year, _),
  )
}
