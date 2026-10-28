# CVProgrammer

A native macOS app for reading and writing DCC decoder Configuration Variables (CVs), monitoring R-BUS feedback, and configuring supported Roco modules. Built with Swift and SwiftUI.

## Features

- **Locomotive programming:** read and write individual CVs, read a CV range, edit individual bits, and bulk-write results.
- **Two command station backends:** Z21/z21 locomotive Programming on the Main (POM) over UDP, and DCC-EX service-mode programming over TCP.
- **CV files:** import and export CSV or JSON, with bundled CV names and descriptions.
- **Z21 accessory programming:** write accessory decoder CVs 1–1024, for decoder addresses 1–512.
- **R-BUS monitoring:** display free, occupied, unknown, and stale inputs, with reconnection handling.
- **Roco modules:** monitor 10808 and 10787 modules and program their R-BUS addresses; monitor the 16-input 10819 Detector X16 and configure its address, detection threshold, response time, and release delay.
- Connection preferences and diagnostic logs.

## Requirements

- **OS:** macOS 12.7 or later (configured deployment target).
- **Command station:** a network-accessible Z21/z21 with LAN communication enabled, or a DCC-EX station with a TCP interface. The Mac must be able to reach its IP address and port.
- **Decoder and track:** a DCC decoder on the main track for Z21 POM, or a programming track connected to DCC-EX for service mode.
- **POM reads:** RailCom must be supported and enabled on both the Z21 and the decoder.
- **Optional feedback hardware:** compatible R-BUS modules connected to the Z21, such as Roco 10808, 10787, or 10819.

Physical hardware is needed for actual programming and feedback; automated tests use simulated transports and services.

## Build and Test

The project uses Apple frameworks only: SwiftUI, Foundation, Network, Combine, and UniformTypeIdentifiers. No third-party packages or dependency installation are required. Swift is configured in Swift 5 language mode; use an Xcode version with Swift Testing support to run the unit tests.

1. Open `CVProgrammer.xcodeproj` in Xcode.
2. Select the application scheme and **My Mac** as the destination.
3. Adjust the signing team if required by your local setup.
4. Press **⌘R** to build and run, or **⌘U** to run the tests.

Tests cover Z21 protocol encoding/decoding, transport and session behavior, R-BUS synchronization and reconnection, device profiles, accessory programming, and UI flows.

## Getting Started

1. Choose **Z21** or **DCC-EX** and set the station's host and port in Settings. Z21 defaults to `192.168.0.111:21105` (UDP); use your configured TCP endpoint for DCC-EX.
2. Connect, then enter the locomotive address for Z21 POM or use the DCC-EX programming track.
3. Read CVs, edit values or bits, and write changes. Export results to CSV or JSON for reuse.
4. With Z21 selected, open **R-BUS Monitor…** to inspect feedback and access module configuration.

## Current Limitations

- The locomotive editor, range reads, and CV import/export currently support CVs **1–255**.
- Accessory POM and Roco 10819 configuration are write-only in the UI. Sending a command does not confirm that the device applied it.
- R-BUS and accessory programming are available through the Z21 backend only.
- For R-BUS address programming, connect only the module being configured and follow the instructions shown in the app.

## TODO

Suggested next steps based on the current implementation:

- [ ] Extend locomotive CV support to 1–1024 across the UI, backends, metadata, and file formats.
- [ ] Add more device profiles and decoder metadata.
- [ ] Expand automated coverage for CV import/export and DCC-EX programming.
- [ ] Document hardware-tested station, firmware, and decoder combinations.
- [ ] Update the architecture documentation to reflect the current R-BUS and device programming implementation.

## License

[MIT](LICENSE) — Copyright © 2026 Luc Dandoy.
