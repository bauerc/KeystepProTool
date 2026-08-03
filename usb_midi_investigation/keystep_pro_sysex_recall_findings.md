# Arturia KeyStep Pro: SysEx Recall Protocol Findings

This document summarizes the reverse-engineered USB SysEx protocol used by the Arturia MIDI Control Center (MCC) to communicate with the KeyStep Pro (KSP) during memory and pattern recall operations.

---

## 1. USB Interface Architecture

The KeyStep Pro exposes **3 main USB interfaces** and **2 virtual MIDI ports/cables** via standard USB MIDI streaming descriptors:

* **Interface 0 (`0xFE`):** Device Firmware Update (DFU)
* **Interface 1 (`0x01`):** Audio / MIDI Control Header
* **Interface 2 (`0x01` / Subclass `0x03`):** MIDI Streaming Interface
  * **Endpoint `0x01` (OUT):** Host to KeyStep Pro communication.
  * **Endpoint `0x81` (IN):** KeyStep Pro to Host bulk data/response stream.

> **Crucial Implementation Note:** macOS / CoreMIDI enumerates two virtual MIDI ports. Standard DAW MIDI note/clock traffic runs on **Port 1**, while MCC proprietary SysEx control commands and recall dumps **must be sent over Port 2 (Control / DIN / Port 2)**. Sending SysEx to Port 1 will be silently dropped by the hardware.

---

## 2. Universal Handshake Phase

Before initiating memory recall, the host software verifies hardware connectivity and identity.

### Device Identity Request
* **Direction:** Host $ightarrow$ KeyStep Pro (`Endpoint 0x01`)
* **Raw SysEx:** `F0 7E 7F 06 01 F7`
* **Protocol Breakdown:**
  * `F0`: Start of SysEx
  * `7E`: Universal Non-Realtime Header
  * `7F`: Global Target Broadcast
  * `06 01`: General Information — Identity Request
  * `F7`: End of SysEx (EOX)

---

## 3. Memory Recall & Register Access Protocol

Arturia utilizes proprietary SysEx messages for memory polling, setting modifications, and pattern dumps.

### Key Parameter Constants
* **Arturia Manufacturer ID:** `00 20 6B`
* **KeyStep Pro Family/Device ID:** `42`
* **Broadcast Target:** `7F`

---

### Command Structure Breakdown

#### A. Global Recall Mode Request
* **Direction:** Host $ightarrow$ KeyStep Pro (`Endpoint 0x01`)
* **Raw SysEx:** `F0 00 20 6B 7F 42 05 01 F7`
* **Byte Breakdown:**
  * `F0 00 20 6B`: Arturia SysEx Header
  * `7F`: Target Device
  * `42`: KeyStep Pro Device ID
  * `05`: **Command Byte: Read / Request Bulk Fetch**
  * `01`: **Sub-Command: Global Recall Request**
  * `F7`: EOX

---

#### B. Read Register Request
* **Direction:** Host $ightarrow$ KeyStep Pro (`Endpoint 0x01`)
* **Raw SysEx Example:** `F0 00 20 6B 7F 42 01 01 25 78 F7`
* **Byte Breakdown:**
  * `01`: **Command Byte: Read Memory Location**
  * `01 25 78`: **Address Pointer** (`0x012578`)

---

#### C. Register Value Return (Response)
* **Direction:** KeyStep Pro $ightarrow$ Host (`Endpoint 0x81`)
* **Raw SysEx Example:** `F0 00 20 6B 7F 42 02 01 25 78 03 F7`
* **Byte Breakdown:**
  * `02`: **Command Byte: Register Value Return / Parameter Write**
  * `01 25 78`: **Address Pointer** (`0x012578`)
  * `03`: **Data Value** (`0x03` stored at target address)

---

## 4. `tshark` Capture Filtering Reference

To extract clean, lightweight SysEx data from heavy `.pcapng` USB dumps without protocol bloat:

```bash
tshark -r capture.pcapng   -Y "sysex and usb.data_len > 0"   -T json   -e frame.number   -e frame.time_relative   -e usb.src   -e usb.dst   -e usb.endpoint_address   -e usbaudio.sysex.reassembled.data > clean_sysex.json
```
