import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
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
    /// Keystrokes in reverse order (newest first) for O(1) prepend
    keystrokes_rev: List(Keystroke),
    /// Queue of pending chars from keydown events
    pending_chars: List(PendingChar),
    /// Last event time (char or backspace) - baseline for next char
    last_event_time: Option(Float),
    text: String,
  )
}

fn init(_flags) -> Model {
  Model(keystrokes_rev: [], pending_chars: [], last_event_time: None, text: "")
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
      Model(
        ..model,
        pending_chars: list.append(model.pending_chars, [
          PendingChar(key, timestamp),
        ]),
      )

    DeleteKeyDown(timestamp) -> Model(..model, last_event_time: Some(timestamp))

    IgnoredKeyDown -> model

    TextChanged(new_text) -> {
      let old_len = string.length(model.text)
      let new_len = string.length(new_text)
      let added = new_len - old_len

      case int.compare(new_len, old_len), model.pending_chars {
        // Text grew and we have pending chars - consume from queue
        order.Gt, [_, ..] -> {
          let #(new_keystrokes_rev, last_ts) =
            consume_pending_rev(
              model.keystrokes_rev,
              model.pending_chars,
              model.last_event_time,
              added,
            )
          Model(
            keystrokes_rev: new_keystrokes_rev,
            pending_chars: list.drop(model.pending_chars, added),
            last_event_time: Some(last_ts),
            text: new_text,
          )
        }
        // Text same or shrunk with pending char (select + replace)
        order.Eq, [first, ..] | order.Lt, [first, ..] -> {
          let new_keystroke =
            Keystroke(
              char: first.key,
              timestamp: first.timestamp,
              baseline: first.timestamp,
            )
          let chars_to_drop = old_len - new_len + 1
          Model(
            keystrokes_rev: [
              new_keystroke,
              ..list.drop(model.keystrokes_rev, chars_to_drop)
            ],
            pending_chars: list.drop(model.pending_chars, 1),
            last_event_time: Some(first.timestamp),
            text: new_text,
          )
        }
        // Text grew but no pending chars (e.g., paste) - ignore
        order.Gt, [] -> Model(..model, text: new_text)
        // Text same or shrunk without pending - truncate (drop from head)
        _, [] -> {
          let chars_to_drop = old_len - new_len
          Model(
            ..model,
            keystrokes_rev: list.drop(model.keystrokes_rev, chars_to_drop),
            text: new_text,
          )
        }
      }
    }

    Reset -> init(Nil)
  }
}

/// Consume up to n pending chars, prepending to reversed keystrokes list
fn consume_pending_rev(
  keystrokes_rev: List(Keystroke),
  pending: List(PendingChar),
  last_event: Option(Float),
  n: Int,
) -> #(List(Keystroke), Float) {
  let to_consume = list.take(pending, n)
  // Process pending chars, building up the new keystrokes
  let #(new_keystrokes, final_baseline) =
    list.fold(to_consume, #([], last_event), fn(acc, p) {
      let #(new_ks_list, baseline_opt) = acc
      let baseline = option.unwrap(baseline_opt, p.timestamp)
      let new_ks =
        Keystroke(char: p.key, timestamp: p.timestamp, baseline: baseline)
      #([new_ks, ..new_ks_list], Some(p.timestamp))
    })
  // new_keystrokes is in reverse order of to_consume, prepend to keystrokes_rev
  let result = list.append(new_keystrokes, keystrokes_rev)
  let last_ts = option.unwrap(final_baseline, 0.0)
  #(result, last_ts)
}

fn compute_delays(keystrokes: List(Keystroke)) -> List(Float) {
  keystrokes
  |> list.drop(1)
  // First char has no delay
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
  let keystrokes = list.reverse(model.keystrokes_rev)
  let avg = average_delay(keystrokes)
  let avg_text = case avg {
    None -> "Type to measure..."
    Some(ms) -> "Avg delay: " <> float_to_string(ms) <> " ms"
  }
  let char_count = list.length(keystrokes)
  let count_text = "Characters: " <> int.to_string(char_count)

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
    html.pre([], [element.text(format_keystrokes(keystrokes))]),
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
        False -> decode.success(CharKeyDown(normalize_key(key), timestamp))
      }
  }
}

fn normalize_key(key: String) -> String {
  case key {
    "Enter" -> "\\n"
    "Tab" -> "\\t"
    _ -> key
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
    "Escape" -> True
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
