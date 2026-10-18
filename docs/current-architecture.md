# Current CVProgrammer Architecture

## Purpose and Scope

This document describes the architecture observed on the `dev/rbus-support` branch before adding R-BUS support and accessory programming.

It is the deliverable for ticket 001. This ticket does not change any application behavior.

## Project Configuration

- Native macOS application built with SwiftUI.
- Minimum deployment target: macOS 12.7.
- Configured language version: Swift 5.
- Three Xcode targets: application, unit tests, and UI tests.
- No Swift Package or other external dependency is declared in the project.
- Apple frameworks used directly: SwiftUI, Foundation, Network, Combine, and UniformTypeIdentifiers.
- The `SWIFT_TREAT_WARNINGS_AS_ERRORS` setting is not explicitly enabled.

## Entry Point and UI Composition

`CVProgrammerApp` is the `@main` entry point. It creates a `CVMetadataStore`, injects it into `ContentView`, and exposes `SettingsView` as the settings window.

`ContentView` is the main view. It currently owns a large part of the application state and orchestration:

- selection between Z21 and DCC-EX;
- connection and disconnection;
- locomotive address, CV number, and CV value input;
- individual read and write operations;
- CV range reading;
- import, export, and bulk writing;
- bit display and editing;
- Combine event consumption;
- log display.

There is no dedicated ViewModel. Both backends are created directly by `ContentView` with `@StateObject`.

`SettingsView` manages preferences stored with `@AppStorage`: preferred protocol, network address and port, maximum CV number, DCC-EX timeout, and automatic log scrolling.

## Current Processing Chain

```text
CVProgrammerApp
  |
  +-- CVMetadataStore ------------------------------+
  |                                                 |
  v                                                 v
ContentView --------------------------------> CV metadata JSON
  |
  +-- backend selection through CVBackend
  |       |
  |       +-- Z21Client
  |       |     |
  |       |     +-- Z21Protocol
  |       |     |     `-- locomotive POM encoding/decoding
  |       |     |
  |       |     `-- NWConnection UDP
  |       |             `-- z21/Z21, configured port (21105 by default)
  |       |
  |       `-- DCCEXBackend
  |             |
  |             `-- NWConnection TCP
  |                     `-- DCC-EX command station
  |
  +-- CVExport / CSV and JSON import
  `-- BitEditorView
```

## Shared Backend Abstraction

`CVBackend` is a `@MainActor` protocol conforming to `ObservableObject`. It exposes:

- `isRunning` and `logText`;
- a Combine publisher of `CVEvent` values;
- connection and disconnection operations;
- CV read and write operations;
- log management.

CV numbers and values are represented by `UInt8`. The locomotive address is optional in the shared interface so that the DCC-EX backend can operate in service mode without an address.

`CommandStation` is a second abstraction that is not used by the current backends. It partially overlaps `CVBackend`, with different signatures that use `UInt16` for CV numbers.

## Z21 Backend

### Current Responsibilities

`Z21Client` is a `@MainActor` class that combines the following responsibilities:

- creation and lifecycle management of a UDP `NWConnection`;
- datagram sending and receive loop;
- text logging;
- indirect encoding through `Z21Protocol`;
- response decoding;
- CV event publication;
- correlation and timeout handling for asynchronous operations.

The connection uses the user-configured port, 21105 by default. `isRunning` becomes `true` immediately after starting `NWConnection`, before the `.ready` state is received.

Closing the connection cancels it and resolves pending read operations with `nil`. Pending write operations are not resolved during disconnection.

### Existing Programming Support

The Z21 backend only performs locomotive POM programming:

- `LAN_X_CV_POM_READ_BYTE` for reads;
- `LAN_X_CV_POM_WRITE_BYTE` for writes;
- `LAN_X_CV_RESULT` and `LAN_X_CV_NACK` as recognized responses.

POM reading depends on RailCom. The UI informs the user about this requirement.

Asynchronous operations use `CheckedContinuation` values indexed only by CV number, with `Task.sleep` tasks for timeouts. Concurrent requests for the same CV can therefore replace each other's continuation.

### Current Codec

`Z21Protocol` is a stateless namespace of static functions. It can:

- encode locomotive POM reads and writes;
- calculate the X-BUS XOR;
- prefix a dataset with its length;
- recognize a CV response or NACK.

The parser checks some minimum sizes and the X-BUS header, but does not yet validate:

- consistency between `DataLen` and the received size;
- the exact size of each message;
- the incoming XOR;
- errors through a dedicated error type;
- multiple datasets in one datagram.

The comments contain generated citation markers (`contentReference`). They should be replaced with stable documentation references when the codec is implemented.

## DCC-EX Backend

`DCCEXBackend` uses a TCP `NWConnection` and the DCC-EX text protocol. It handles one programming operation at a time through a `PendingProgOp` state, a `progTrackBusy` indicator, and a timeout.

Received messages are accumulated in a buffer, split between `<` and `>`, and converted into CV events. Correlation uses callback identifiers when available, with the CV number as a fallback.

This backend provides service-mode programming on the programming track. It must remain operational throughout the Z21 changes.

## State, Concurrency, and Errors

- `Z21Client`, `DCCEXBackend`, and `CVBackend` are isolated to the `MainActor`.
- `NWConnection` callbacks return to the `MainActor` through `Task`.
- Combine transports results to `ContentView`.
- `async/await` is used for some read/write loops and timeouts.
- There is currently no `actor`, `AsyncStream`, injected transport, or independent business service.
- Network and protocol errors are primarily converted to strings in the log or in `CVEvent.failure`.
- Both backend logs are limited to the latest 100 lines.

## Import, Export, and Metadata

`CVMetadataStore` loads `cv_metadata.json` from the application bundle and provides CV descriptions.

`CVExport` supports CSV and JSON through `FileDocument`. Import, validation, and bulk writing are orchestrated by `ContentView`.

## Existing Tests

The test targets use XCTest.

- `CVProgrammerTests` only contains the example methods generated by Xcode, without business assertions.
- `CVProgrammerUITests` launches the application but does not verify any behavior.
- The launch test produces a screenshot.
- No test currently covers Z21 frames, timeouts, backends, import/export, or preferences.
- No current test requires a physical command station.

## Files Outside the Xcode Project Organization

Two source files exist in the repository directory but do not appear in the Xcode project organization:

- `CVProgrammer/CVMEtadata.old.swift`;
- `CVProgrammer/DCCEXCommandStation.swift`.

They do not participate in the observed build and should not be treated as active components without an explicit future decision.

The `CVProgrammer.xcodeproj/xcshareddata/` directory was present but untracked by Git at the time of the audit. Ticket 001 does not modify it.

## R-BUS Support Status

This branch currently contains no R-BUS support:

- no `LAN_RMBUS_GETDATA` command;
- no `LAN_RMBUS_DATACHANGED` decoding;
- no broadcast flag management;
- no free, occupied, or unknown input model;
- no initial synchronization;
- no monitoring view;
- no Roco 10819 profile.

The branch is therefore a suitable baseline for tickets 002 through 016, without requiring migration of an earlier R-BUS prototype.

## Recommended Extension Points

1. Move ownership of `NWConnection` out of `Z21Client` and behind a single injectable UDP `Z21Transport`.
2. Evolve `Z21Protocol` into a pure, typed, and testable codec before adding new commands.
3. Introduce a SwiftUI-independent Z21 session for the connection lifecycle, broadcast flags, and message routing.
4. Keep `CVBackend` as a compatibility façade during migration to avoid breaking `ContentView`.
5. Build `RBusService` on top of the single session, without creating a second UDP socket.
6. Add dedicated `@MainActor` ViewModels for R-BUS monitoring and device profiles.
7. Centralize programming targets to distinguish locomotive, accessory, R-BUS, and 10819 pseudo-addresses.

## Regression Risks

- Changes to the existing locomotive POM frame bytes while moving them into the codec.
- Changes to RailCom reads, timeout behavior, or Combine event ordering.
- Accidental creation of multiple UDP sockets for the same Z21.
- Breaking dynamic selection between Z21 and DCC-EX in `ContentView`.
- Lost or double-resumed continuations during disconnection and cancellation.
- Confusion between a sent POM write and a confirmed write, because POM writes do not necessarily receive a response.
- Premature extension beyond CV 255 without consistently migrating the models, metadata, import/export, and UI.
- Blocking the `MainActor` if continuous reception or resynchronization is implemented synchronously.
- Regressions in import/export or bulk writing, which are currently coupled to `ContentView` and `CVBackend`.

## References for Future Work

- Official public Roco documentation for the Z21 Detector X16 10819.
- Official Z21 LAN Protocol Specification, version 1.13 dated November 6, 2023, which was the latest published version at the time of the audit.
- Documents and tickets in the `Z21CVProgrammer_RBUS_Accessories_Spec` directory.

## Ticket 001 Validation

Validation was performed on October 18, 2026, using the `Z21CVProgrammer` scheme and the `My Mac` destination:

- build including the test targets: successful, with no errors reported by Xcode;
- unit tests: 2 passed, 0 failed;
- discovered UI tests: 3;
- executed UI tests: Xcode produced no result (`No result`), including during a second targeted run;
- no UI test error was reported, but their effective execution cannot be considered validated.

The existing tests are only the templates generated by Xcode. The UI tests' `No result` status is a configuration/CI issue to address in ticket 015; it does not justify a functional change in the audit ticket.
