import Foundation

struct LocomotiveAddress: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

enum ProgrammingAddressError: Error, Equatable, LocalizedError, Sendable {
    case invalidAccessoryAddress(UInt16)

    var errorDescription: String? {
        switch self {
            case .invalidAccessoryAddress(let address):
                return "Accessory decoder address \(address) is outside the supported range 1...512."
        }
    }
}

struct AccessoryAddress: Codable, Hashable, Sendable {
    let value: UInt16

    init(_ value: UInt16) throws {
        guard (1...512).contains(value) else {
            throw ProgrammingAddressError.invalidAccessoryAddress(value)
        }
        self.value = value
    }

    var zeroBasedValue: UInt16 {
        value - 1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(UInt16.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum ProgrammingMode: String, Codable, Sendable {
    case serviceMode
    case pomLocomotive
    case pomAccessory
}

enum ProgrammingTarget: Equatable, Sendable {
    case locomotive(address: LocomotiveAddress)
    case accessory(address: AccessoryAddress)
    case deviceProfile(DeviceProfile)
}

enum DeviceProfileValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidCV(UInt16)
    case invalidValueRange(parameterID: String, minimum: UInt8, maximum: UInt8)
    case duplicateParameterID(String)
    case parameterNotFound(String)
    case valueOutOfRange(parameterID: String, value: UInt8, minimum: UInt8, maximum: UInt8)

    var errorDescription: String? {
        switch self {
            case .invalidCV(let cv):
                return "CV \(cv) is outside the supported range 1...1024."
            case .invalidValueRange(let id, let minimum, let maximum):
                return "Parameter \(id) has an invalid range \(minimum)...\(maximum)."
            case .duplicateParameterID(let id):
                return "Parameter identifier \(id) is duplicated."
            case .parameterNotFound(let id):
                return "Parameter \(id) was not found."
            case .valueOutOfRange(let id, let value, let minimum, let maximum):
                return "Value \(value) for parameter \(id) is outside \(minimum)...\(maximum)."
        }
    }
}

struct DeviceParameter: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let cv: UInt16
    let minimum: UInt8
    let maximum: UInt8
    let unit: String?
    let help: String?
    let isReadSupported: Bool

    init(
        id: String,
        name: String,
        cv: UInt16,
        minimum: UInt8,
        maximum: UInt8,
        unit: String? = nil,
        help: String? = nil,
        isReadSupported: Bool
    ) throws {
        guard (1...1_024).contains(cv) else {
            throw DeviceProfileValidationError.invalidCV(cv)
        }
        guard minimum <= maximum else {
            throw DeviceProfileValidationError.invalidValueRange(
                parameterID: id,
                minimum: minimum,
                maximum: maximum
            )
        }

        self.id = id
        self.name = name
        self.cv = cv
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.help = help
        self.isReadSupported = isReadSupported
    }

    func validate(_ value: UInt8) throws {
        guard (minimum...maximum).contains(value) else {
            throw DeviceProfileValidationError.valueOutOfRange(
                parameterID: id,
                value: value,
                minimum: minimum,
                maximum: maximum
            )
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            cv: values.decode(UInt16.self, forKey: .cv),
            minimum: values.decode(UInt8.self, forKey: .minimum),
            maximum: values.decode(UInt8.self, forKey: .maximum),
            unit: values.decodeIfPresent(String.self, forKey: .unit),
            help: values.decodeIfPresent(String.self, forKey: .help),
            isReadSupported: values.decode(Bool.self, forKey: .isReadSupported)
        )
    }
}

struct DeviceProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let manufacturer: String
    let model: String
    let programmingMode: ProgrammingMode
    let pseudoAddress: UInt16?
    let parameters: [DeviceParameter]

    init(
        id: String,
        manufacturer: String,
        model: String,
        programmingMode: ProgrammingMode,
        pseudoAddress: UInt16? = nil,
        parameters: [DeviceParameter]
    ) throws {
        var parameterIDs = Set<String>()
        for parameter in parameters {
            guard parameterIDs.insert(parameter.id).inserted else {
                throw DeviceProfileValidationError.duplicateParameterID(parameter.id)
            }
        }

        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.programmingMode = programmingMode
        self.pseudoAddress = pseudoAddress
        self.parameters = parameters
    }

    func parameter(id: String) throws -> DeviceParameter {
        guard let parameter = parameters.first(where: { $0.id == id }) else {
            throw DeviceProfileValidationError.parameterNotFound(id)
        }
        return parameter
    }

    func validate(value: UInt8, forParameterID id: String) throws {
        try parameter(id: id).validate(value)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            manufacturer: values.decode(String.self, forKey: .manufacturer),
            model: values.decode(String.self, forKey: .model),
            programmingMode: values.decode(ProgrammingMode.self, forKey: .programmingMode),
            pseudoAddress: values.decodeIfPresent(UInt16.self, forKey: .pseudoAddress),
            parameters: values.decode([DeviceParameter].self, forKey: .parameters)
        )
    }
}
