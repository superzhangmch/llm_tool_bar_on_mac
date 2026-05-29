# LLM Tool Bar (EngBar)

A tiny macOS menu-bar assistant bar that talks to an OpenAI/Anthropic-style
chat endpoint (designed for a local [LiteLLM](https://github.com/BerriAI/litellm)
proxy). It floats a borderless input bar at the top of the screen, streams the
reply into a dropdown, and has one-shot English helpers (correct / explain /
etymology).

Single-file SwiftUI + AppKit app — all of `EngBar.swift`.

(By AI, for personal use only)

## Features

- Floating, borderless top bar; summoned from the menu-bar icon, hides on blur.
- Streaming responses (Anthropic `/v1/messages` SSE), rendered as Markdown in a
  native `NSTextView` (selectable, copyable, with table support).
- Multi-turn chat with a 10-minute idle cutoff; `/` prefix forces a new session.
- Model picker populated live from the proxy's `/v1/models`, persisted locally.
- One-shot English tools, prompt-wrapped so you can still follow up:
  - **纠** — corrector (two versions: light edit + native rewrite)
  - **解读** — explain a hard sentence
  - **词源** — etymology
- Prompt caching (`cache_control: ephemeral`), TTFT + token-usage readout,
  stop / retry / copy controls, readline-style `Ctrl+U` / `Ctrl+W` in the input.

<img width="1218" height="866" alt="image" src="https://github.com/user-attachments/assets/92551813-a755-4398-8933-db237a405d57" />

## Build

Requires the Xcode command-line tools (`swiftc`) on Apple Silicon macOS 13+.

```sh
./build.sh          # build into ./build/EngBar.app
./build.sh install  # also copy to ~/Applications and relaunch
```

## Configure

Runtime config is read once at launch from
`~/Library/Application Support/EngBar/config.json`. Copy the example and edit:

```sh
mkdir -p "$HOME/Library/Application Support/EngBar"
cp config.example.json "$HOME/Library/Application Support/EngBar/config.json"
# then edit apiBase / apiKey / defaultModel
```

| field          | meaning                                  | default                 |
|----------------|------------------------------------------|-------------------------|
| `apiBase`      | proxy base URL (no trailing `/v1/...`)   | `http://localhost:4001` |
| `apiKey`       | API key sent as `x-api-key` / `Bearer`   | `sk-123`                |
| `defaultModel` | model selected on first launch           | `claude-sonnet-4-6`     |

Missing file or fields fall back to the defaults above, so it runs with zero
config against a local proxy. The real `config.json` is git-ignored — never
commit your key.
