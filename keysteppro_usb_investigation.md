# Keystep Pro Recall Findings

## Recall Sysex Dump File

A USB call from the MCC software to the Keystep Pro was monitored via Wireshark and dumped. This captured the USB Midi actions done by the PC and the machine to retrieve Project 1 from the device. The files are as follows:

* `recall_sysex.jsonl` - The entire dump from start to finish capturing only calls that output data
* `sysex_until_project_1_track_1_pattern_1.jsonl` - A truncated file that goes up until the specified call which retrieves the specific subset of information. This is the 16 step note MIDI sequence on the device.
* `initial_project_hex_map.txt` - A dump of the `initial_project.KeyStepPro` json file so that the values are mapped to hex.
    * Of note, the format "123_109_1_1_1" seems to correspond as Track-Pitch Value-Pattern-Unknown-Step. This information is  better specified in this project in the [KeyStepPro_Format_Spec.md](analysis/KeyStepPro_Format_Spec.md)

## Setup Call

From my investigation recorded in `sysex_mvp_call.txt` (which can be used in conjunction with the `replay_handshake.py` script), every call to open up the Arturia KeyStep Pro must start with these calls. The frame values correspond to the values found in `recall_sysex.jsonl` for this sequence

|[Frame Number] | [Clean SysEx Bytes] |
| ------- | -----------|
| Frame 7 | f0 7e 7f 06 01 f7  |
| Frame 11 | f0 00 20 6b 7f 42 05 01 f7  |

**Correction — frame 13 is not part of the handshake.** It was originally listed above as a third
setup call. Decoding the protocol showed it is the **first read of the recall itself**: the short
request form for `paramId 37, itemId 120` (`25` = 37, `78` = 120), and its reply
`f0 00 20 6b 7f 42 02 01 25 78 03 f7` carries that key's value, `3`. Frames 7 and 11 are the
genuine handshake. See [§7 of the format spec](analysis/format/SysEx_Direct_Transfer_Path.md).

|[Frame Number] | [Clean SysEx Bytes] | [What it actually is] |
| ------- | -----------| --- |
| Frame 13 | f0 00 20 6b 7f 42 01 01 25 78 f7 | The first read, not a setup call |

## Retrieval Call

The Keystep pro has tons of various attributes to extract. Almost assuredly the request maps 1-to-1 with the formats specified the KeyStepPro project files. A deeper analysis should be done and deeper tests written. For now this is a list of known calls that do work.

The following 4 byte sequences when called AFTER the Setup Calls perfectly retreive the expected values from Project 1 Track 1 Pattern 1

|[Frame Number] | [Clean SysEx Bytes] |
| ------- | -----------|
| Frame 5845 | f0 00 20 6b 7f 42 0b 01 6d 03 7b 01 01 01 10 f7 |
| Frame 5847 | f0 00 20 6b 7f 42 0b 01 6d 03 7b 01 01 11 10 f7 |
| Frame 5849 | f0 00 20 6b 7f 42 0b 01 6d 03 7b 01 01 21 10 f7 |
| Frame 5851 | f0 00 20 6b 7f 42 0b 01 6d 03 7b 01 01 31 10 f7 |

To break down further for some understanding:
| HEX| INT | BINARY   | COMMENT |
| ---| --- | ---------| --------|
| f0 | 240 | 11110000 | Start of Sequence |
| 00 |   0 | 00000000 | |
| 20 |  32 | 00100000 | |
| 6b | 107 | 01101011 | |
| 7f | 127 | 01111111 | |
| 42 |  66 | 01000010 | |
| 0b |  11 | 00001011 | |
| 01 |   1 | 00000001 | |
| 6d | 109 | 01101101 | Parameter (109 is for pitch) |
| 03 |   3 | 00000011 | |
| 7b | 123 | 01111011 | Track value |
| 01 |   1 | 00000001 | Pattern (1 - 16) |
| 01 |   1 | 00000001 | Unknown?|
| 01 |   1 | 00110001 | Step Number to Start Scan|
| 10 |  16 | 00010000 | Number of BYTES requested|
| f7 | 247 | 11110111 | End of Sequence|

Due to this, the pen ultimate byte allows us to construct a call that request 64 bytes instead of 16!

Sending this sequence (after the Steup call):
 ```
 Frame TEST | f0 00 20 6b 7f 42 0b 01 6d 03 7b 01 01 01 40 f7
 ```
Resulted in this response:
```
"Frame TEST" : f0 00 20 6b 7f 42 0c 01 6d 03 7b 01 01 01 40 48 4c 4f 4c 4a 4d 51 4d 4c 4f 53 4f 48 4c 4f 4c 48 4c 4f 4c 4c 4f 53 4f 51 54 58 54 48 4c 4f 4c 48 4c 4f 4c 4a 4d 51 4d 51 54 58 54 48 4c 4f 4c 48 4c 4f 4c 4a 4d 51 4d 4c 4f 53 4f 51 54 58 51 f7 00 f0 00 20 6b 7f 42 1c 00 f7
```
