import gleam/dynamic/decode
import gleam/int
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn main() {
  let app = lustre.simple(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

/// Each keystroke stores its character, timestamp, and baseline for delay calculation
type Keystroke {
  Keystroke(char: String, timestamp: Float, baseline: Float)
}

type PendingChar {
  PendingChar(key: String, timestamp: Float)
}

type Model {
  Model(
    keystrokes: List(Keystroke),
    /// Pending char from keydown
    pending_char: Option(PendingChar),
    /// Last event time (char or backspace) - baseline for next char
    last_event_time: Option(Float),
    text: String,
  )
}

fn init(_flags) -> Model {
  Model(keystrokes: [], pending_char: None, last_event_time: None, text: "")
}

type Msg {
  CharKeyDown(key: String, timestamp: Float)
  DeleteKeyDown(timestamp: Float)
  IgnoredKeyDown
  TextChanged(text: String)
  Reset
}

fn update(model: Model, msg: Msg) -> Model {
  case msg {
    CharKeyDown(key, timestamp) ->
      Model(..model, pending_char: Some(PendingChar(key, timestamp)))

    DeleteKeyDown(timestamp) ->
      Model(..model, last_event_time: Some(timestamp))

    IgnoredKeyDown -> model

    TextChanged(new_text) -> {
      let old_len = string.length(model.text)
      let new_len = string.length(new_text)

      case new_len > old_len, model.pending_char {
        // Text grew and we have a pending char
        True, Some(pending) -> {
          let baseline = option.unwrap(model.last_event_time, 0.0)
          let new_keystroke =
            Keystroke(char: pending.key, timestamp: pending.timestamp, baseline: baseline)
          let added = new_len - old_len
          let new_keystrokes = add_keystrokes(model.keystrokes, new_keystroke, added)
          Model(
            keystrokes: new_keystrokes,
            pending_char: None,
            last_event_time: Some(pending.timestamp),
            text: new_text,
          )
        }
        // Text grew but no pending char (e.g., paste) - ignore
        True, None -> Model(..model, text: new_text)
        // Text shrunk - truncate keystrokes (last_event_time already set by DeleteKeyDown)
        False, _ -> {
          Model(
            ..model,
            keystrokes: list.take(model.keystrokes, new_len),
            pending_char: None,
            text: new_text,
          )
        }
      }
    }

    Reset -> init(Nil)
  }
}

fn add_keystrokes(keystrokes: List(Keystroke), ks: Keystroke, n: Int) -> List(Keystroke) {
  case n <= 0 {
    True -> keystrokes
    False -> {
      let new_entries = list.repeat(ks, n)
      list.append(keystrokes, new_entries)
    }
  }
}

fn compute_delays(keystrokes: List(Keystroke)) -> List(Float) {
  keystrokes
  |> list.drop(1)  // First char has no delay
  |> list.map(fn(ks) { ks.timestamp -. ks.baseline })
}

fn average_delay(keystrokes: List(Keystroke)) -> Option(Float) {
  let delays = compute_delays(keystrokes)
  case delays {
    [] -> None
    _ -> {
      let sum = list.fold(delays, 0.0, fn(acc, d) { acc +. d })
      let count = int.to_float(list.length(delays))
      Some(sum /. count)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  let avg = average_delay(model.keystrokes)
  let avg_text = case avg {
    None -> "Type to measure..."
    Some(ms) -> "Avg delay: " <> float_to_string(ms) <> " ms"
  }
  let char_count = list.length(model.keystrokes)
  let count_text = "Characters: " <> int.to_string(char_count)

  html.div([], [
    html.link([
      attribute.rel("stylesheet"),
      attribute.href("https://cdn.simplecss.org/simple.min.css"),
    ]),
    html.main([], [
      html.h1([], [element.text("Keystroke Delay Calculator")]),
      html.textarea(
        [
          attribute.id("input"),
          attribute.placeholder("Start typing here..."),
          attribute.attribute("rows", "6"),
          attribute.value(model.text),
          event.on("keydown", decode_keydown()),
          event.on_input(TextChanged),
        ],
        "",
      ),
      html.p([], [element.text(avg_text)]),
      html.p([], [element.text(count_text)]),
      html.button([event.on_click(Reset)], [element.text("Reset")]),
      html.h2([], [element.text("Keystroke Log")]),
      html.pre([], [element.text(format_keystrokes(model.keystrokes))]),
    ]),
  ])
}

fn format_keystrokes(keystrokes: List(Keystroke)) -> String {
  keystrokes
  |> list.index_map(fn(ks, i) {
    let delay = case i {
      0 -> "-"
      _ -> float_to_string(ks.timestamp -. ks.baseline) <> "ms"
    }
    int.to_string(i + 1)
    <> ": '"
    <> ks.char
    <> "' timestamp="
    <> float_to_string(ks.timestamp)
    <> " baseline="
    <> float_to_string(ks.baseline)
    <> " delay="
    <> delay
  })
  |> string.join("\n")
}

fn decode_keydown() -> decode.Decoder(Msg) {
  use key <- decode.field("key", decode.string)
  use timestamp <- decode.field("timeStamp", decode.float)
  case key {
    "Backspace" | "Delete" -> decode.success(DeleteKeyDown(timestamp))
    _ ->
      case is_ignored_key(key) {
        True -> decode.success(IgnoredKeyDown)
        False -> decode.success(CharKeyDown(key, timestamp))
      }
  }
}

fn is_ignored_key(key: String) -> Bool {
  case key {
    // Navigation
    "ArrowUp" | "ArrowDown" | "ArrowLeft" | "ArrowRight" -> True
    "Home" | "End" | "PageUp" | "PageDown" -> True
    // Modifiers
    "Shift" | "Control" | "Alt" | "Meta" -> True
    "CapsLock" | "NumLock" | "ScrollLock" -> True
    // Function keys
    "Escape" | "Tab" -> True
    "F1" | "F2" | "F3" | "F4" | "F5" | "F6" -> True
    "F7" | "F8" | "F9" | "F10" | "F11" | "F12" -> True
    // Other non-character keys
    "Insert" | "Pause" | "PrintScreen" -> True
    "ContextMenu" -> True
    _ -> False
  }
}

fn float_to_string(f: Float) -> String {
  let rounded = float.round(f *. 100.0)
  let whole = rounded / 100
  let frac = int.absolute_value(rounded % 100)
  let frac_str = case frac < 10 {
    True -> "0" <> int.to_string(frac)
    False -> int.to_string(frac)
  }
  int.to_string(whole) <> "." <> frac_str
}
