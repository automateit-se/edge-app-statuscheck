# Status check - Statuskontroll (IoT Open edge app)

An IoT Open edge app that, when triggered, checks the current state of chosen functions and tells what is not as
it should be: *"Altandörren är öppen"*, *"Kaffebryggaren är på"*, or *"Allt är ok"*. Made for a button the resident
presses before going to sleep or leaving the flat.

Technical names (metadata keys, topics, payload) are in English; the form is in Swedish.

## How it works

- **The check is a function** of type `button` (name from the form), created by the app:
  - `set/obj/statuscheck/<group>` with value `1` runs the check (the dashboard's push button, or anything else).
    An extra topic, for example a KNX button's `set/obj/house/.../status_check`, can run it too (`trigger_topic`).
  - `obj/statuscheck/<group>` (retained): the number of deviations after the last check, and in `msg` what they
    were, for example `Altandörren är öppen, Kaffebryggaren är på`, or `Allt är ok`.
- **Every item** (*Det här kontrolleras*): a function found with the function selector, when it deviates (`active` -
  open or on, `inactive` - closed or off, `above` / `below` a value, `equal` to a value), the text and the sound.
  What is as it should be is not told.
- **What happens**: the sounds of the deviations, one after another, `gap_s` seconds apart (default 4), on the
  installation's speaker (the Play function of a device of type `audio`, from
  [ha-iotopen](https://github.com/automateit-se/ha-iotopen)); with no deviation the ok sound. A new check stops the
  sounds of one still playing. Optionally a notification with the texts (`notify_outputs`, a group from
  [Recipients](https://github.com/automateit-se/edge-app-recipients)), by default only when something deviates.
- **Unknown status**: a function that has not reported a value is told as `<name>: okänd status`, with its own
  sound if set, never as ok. At the start the latest values are read from IoT Open, so things that seldom report
  are known at once.

See [examples/flat.json](examples/flat.json) for a flat with ten things to check (function ids
are examples).

## Settings, the function and the metadata

The settings are stored as metadata in IoT Open and kept in step with the form both ways; **whoever changed last
wins**, as in [För länge](https://github.com/automateit-se/edge-app-toolong) 0.4:

| Where | Metadata | Form |
|---|---|---|
| each item's function | `statuscheck.group`, `.when`, `.value`, `.text`, `.sound` | *Det här kontrolleras* |
| the check function | `statuscheck.ok_text`, `.ok_sound`, `.unknown_text`, `.unknown_sound`, `.gap_s` | *Vad som händer* |

So the check function carries its own settings, and a change in IoT Open's front end or another system comes back
into the form. The form the app last applied is kept retained (`obj/statuscheck/<group>/form`), so a restart is
not taken for a change. A function can be in several checks (`statuscheck.group` is a comma separated list), but
its text and sound are shared.

The form has three pages: *Kontroll*, *Vad som händer* and *Avancerat* (`trigger_topic`, `player_device`, `group`,
`active_value`).

## Payload of the notification

| Key | Example |
|---|---|
| `instance` | `Statuskontroll` |
| `count` | `2` |
| `ok` | `false` |
| `text` | `Altandörren är öppen, Kaffebryggaren är på` |
| `recipients_email`, `recipients_sms` | from the Recipients app |
| `late` | `true` when queued for more than an hour (no internet) |

## Tests

```bash
lua5.3 tests/test_app.lua
```

The tests run `app.lua` in a simulated edge client. All names, addresses and numbers in the tests are made up.

## License

MIT
