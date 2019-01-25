import Foundation
import SourceKittenFramework

private let kindsImplyingObjc: Set<SwiftDeclarationAttributeKind> =
    [.ibaction, .iboutlet, .ibinspectable, .gkinspectable, .ibdesignable, .nsManaged]

public struct RedundantObjcAttributeRule: ConfigurationProviderRule, AutomaticTestableRule {
    public var configuration = SeverityConfiguration(.warning)

    public init() {}

    public static let description = RuleDescription(
        identifier: "redundant_objc_attribute",
        name: "Redundant @objc Attribute",
        description: "Objective-C attribute (@objc) is redundant in declaration.",
        kind: .idiomatic,
        minSwiftVersion: .fourDotOne,
        nonTriggeringExamples: RedundantObjcAttributeRule.nonTriggeringExamples,
        triggeringExamples: RedundantObjcAttributeRule.triggeringExamples,
        corrections: RedundantObjcAttributeRule.corrections)

    public func validate(file: File) -> [StyleViolation] {
        return violationRanges(file: file, dictionary: file.structure.dictionary, parentStructure: nil).map {
            StyleViolation(ruleDescription: type(of: self).description,
                           severity: configuration.severity,
                           location: Location(file: file, characterOffset: $0.location))
        }
    }

    private func violationRanges(file: File, dictionary: [String: SourceKitRepresentable],
                                 parentStructure: [String: SourceKitRepresentable]?) -> [NSRange] {
        return dictionary.substructure.flatMap { subDict -> [NSRange] in
            var violations = violationRanges(file: file, dictionary: subDict, parentStructure: dictionary)

            if let kindString = subDict.kind,
                let kind = SwiftDeclarationKind(rawValue: kindString) {
                violations += violationRanges(file: file, kind: kind, dictionary: subDict, parentStructure: dictionary)
            }

            return violations
        }
    }

    private func violationRanges(file: File,
                                 kind: SwiftDeclarationKind,
                                 dictionary: [String: SourceKitRepresentable],
                                 parentStructure: [String: SourceKitRepresentable]?) -> [NSRange] {
        let objcAttribute = dictionary.swiftAttributes
                                      .first(where: { $0.attribute == SwiftDeclarationAttributeKind.objc.rawValue })
        guard let objcOffset = objcAttribute?.offset,
              let objcLength = objcAttribute?.length,
              let range = file.contents.bridge().byteRangeToNSRange(start: objcOffset, length: objcLength),
              !dictionary.isObjcAndIBDesignableDeclaredExtension else {
            return []
        }

        let isInObjcVisibleScope = { () -> Bool in
            guard let parentStructure = parentStructure,
                let kind = dictionary.kind.flatMap(SwiftDeclarationKind.init),
                let parentKind = parentStructure.kind.flatMap(SwiftDeclarationKind.init),
                let acl = dictionary.accessibility.flatMap(AccessControlLevel.init(identifier:)) else {
                    return false
            }

            let isInObjCExtension = [.extensionClass, .extension].contains(parentKind) &&
                parentStructure.enclosedSwiftAttributes.contains(.objc)

            let isInObjcMembers = parentStructure.enclosedSwiftAttributes.contains(.objcMembers) && !acl.isPrivate

            guard isInObjCExtension || isInObjcMembers else {
                return false
            }

            return !SwiftDeclarationKind.typeKinds.contains(kind)
        }

        let isUsedWithObjcAttribute = !Set(dictionary.enclosedSwiftAttributes).isDisjoint(with: kindsImplyingObjc)

        if isUsedWithObjcAttribute || isInObjcVisibleScope() {
            return [range]
        }

        return []
    }
}

private extension Dictionary where Key == String, Value == SourceKitRepresentable {
    var isObjcAndIBDesignableDeclaredExtension: Bool {
        guard let kind = kind, let declaration = SwiftDeclarationKind(rawValue: kind) else {
            return false
        }
        return [.extensionClass, .extension].contains(declaration)
            && Set(enclosedSwiftAttributes).isSuperset(of: [.ibdesignable, .objc])
    }
}

extension RedundantObjcAttributeRule: CorrectableRule {
    public func correct(file: File) -> [Correction] {
        let ranges = violationRanges(file: file, dictionary: file.structure.dictionary, parentStructure: nil)
                                      .filter { !file.ruleEnabled(violatingRanges: [$0], for: self).isEmpty }
        guard !ranges.isEmpty else { return [] }

        let description = type(of: self).description
        var corrections = [Correction]()
        var contents = file.contents
        for range in ranges.reversed() {
            var whitespaceAndNewlinesOffset = 0
            let bridgeCharSet = CharacterSet.whitespacesAndNewlines.bridge()
            while bridgeCharSet
                .characterIsMember(contents.bridge().character(at: range.upperBound + whitespaceAndNewlinesOffset)) {
                whitespaceAndNewlinesOffset += 1
            }

            let withTrailingWhitespaceAndNewlinesRange = NSRange(location: range.location,
                                                                 length: range.length + whitespaceAndNewlinesOffset)
            contents = contents.bridge().replacingCharacters(in: withTrailingWhitespaceAndNewlinesRange, with: "")
            let location = Location(file: file, characterOffset: range.location)
            corrections.append(Correction(ruleDescription: description, location: location))
        }

        file.write(contents)
        return corrections
    }
}

extension RedundantObjcAttributeRule {
    static let nonTriggeringExamples = [
        "@objc private var foo: String? {}",
        "@IBInspectable private var foo: String? {}",
        "@objc private func foo(_ sender: Any) {}",
        "@IBAction private func foo(_ sender: Any) {}",
        "@GKInspectable private var foo: String! {}",
        "private @GKInspectable var foo: String! {}",
        "@NSManaged var foo: String!",
        "@objc @NSCopying var foo: String!",
        """
        @objcMembers
        class Foo {
            var bar: Any?
            @objc
            class Bar {
                @objc
                var foo: Any?
            }
        }
        """,
        """
        @objc
        extension Foo {
            var bar: Int {
                return 0
            }
        }
        """,
        """
        extension Foo {
            @objc
            var bar: Int { return 0 }
        }
        """,
        """
        @objc @IBDesignable
        extension Foo {
            var bar: Int { return 0 }
        }
        """,
        """
        @IBDesignable
        extension Foo {
            @objc
            var bar: Int { return 0 }
            var fooBar: Int { return 1 }
        }
        """,
        """
        @objcMembers
        class Foo: NSObject {
            @objc
            private var bar: Int {
                return 0
            }
        }
        """,
        """
        @objcMembers
        class Foo {
            class Bar: NSObject {
                @objc var foo: Any
            }
        }
        """,
        """
        @objcMembers
        class Foo {
            @objc class Bar {}
        }
        """
    ]

    static let triggeringExamples = [
        "↓@objc @IBInspectable private var foo: String? {}",
        "@IBInspectable ↓@objc private var foo: String? {}",
        "↓@objc @IBAction private func foo(_ sender: Any) {}",
        "@IBAction ↓@objc private func foo(_ sender: Any) {}",
        "↓@objc @GKInspectable private var foo: String! {}",
        "@GKInspectable ↓@objc private var foo: String! {}",
        "↓@objc @NSManaged private var foo: String!",
        "@NSManaged ↓@objc private var foo: String!",
        "↓@objc @IBDesignable class Foo {}",
        """
        @objcMembers
        class Foo {
            ↓@objc var bar: Any?
        }
        """,
        """
        @objcMembers
        class Foo {
            ↓@objc var bar: Any?
            ↓@objc var foo: Any?
            @objc
            class Bar {
                @objc
                var foo: Any?
            }
        }
        """,
        """
        @objc
        extension Foo {
            ↓@objc
            var bar: Int {
                return 0
            }
        }
        """,
        """
        @objc @IBDesignable
        extension Foo {
            ↓@objc
            var bar: Int {
                return 0
            }
        }
        """,
        """
        @objcMembers
        class Foo {
            @objcMembers
            class Bar: NSObject {
                ↓@objc var foo: Any
            }
        }
        """,
        """
        @objc
        extension Foo {
            ↓@objc
            private var bar: Int {
                return 0
            }
        }
        """
    ]

    static let corrections = [
        "↓@objc @IBInspectable private var foo: String? {}": "@IBInspectable private var foo: String? {}",
        "@IBInspectable ↓@objc private var foo: String? {}": "@IBInspectable private var foo: String? {}",
        "@IBAction ↓@objc private func foo(_ sender: Any) {}": "@IBAction private func foo(_ sender: Any) {}",
        "↓@objc @GKInspectable private var foo: String! {}": "@GKInspectable private var foo: String! {}",
        "@GKInspectable ↓@objc private var foo: String! {}": "@GKInspectable private var foo: String! {}",
        "↓@objc @NSManaged private var foo: String!": "@NSManaged private var foo: String!",
        "@NSManaged ↓@objc private var foo: String!": "@NSManaged private var foo: String!",
        "↓@objc @IBDesignable class Foo {}": "@IBDesignable class Foo {}",
        """
        @objcMembers
        class Foo {
            ↓@objc var bar: Any?
        }
        """:
        """
        @objcMembers
        class Foo {
            var bar: Any?
        }
        """,
        """
        @objcMembers
        class Foo {
            ↓@objc var bar: Any?
            ↓@objc var foo: Any?
            @objc
            class Bar {
                @objc
                var foo2: Any?
            }
        }
        """:
        """
        @objcMembers
        class Foo {
            var bar: Any?
            var foo: Any?
            @objc
            class Bar {
                @objc
                var foo2: Any?
            }
        }
        """,
        """
        @objc
        extension Foo {
            ↓@objc
            var bar: Int {
                return 0
            }
        }
        """:
        """
        @objc
        extension Foo {
            var bar: Int {
                return 0
            }
        }
        """,
        """
        @objc @IBDesignable
        extension Foo {
            ↓@objc
            var bar: Int {
                return 0
            }
        }
        """:
        """
        @objc @IBDesignable
        extension Foo {
            var bar: Int {
                return 0
            }
        }
        """,
        """
        @objcMembers
        class Foo {
            @objcMembers
            class Bar: NSObject {
                ↓@objc var foo: Any
            }
        }
        """:
        """
        @objcMembers
        class Foo {
            @objcMembers
            class Bar: NSObject {
                var foo: Any
            }
        }
        """,
        """
        @objc
        extension Foo {
            ↓@objc
            private var bar: Int {
                return 0
            }
        }
        """:
        """
        @objc
        extension Foo {
            private var bar: Int {
                return 0
            }
        }
        """,
        """
        @objc
        extension Foo {
            ↓@objc


            private var bar: Int {
                return 0
            }
        }
        """:
        """
        @objc
        extension Foo {
            private var bar: Int {
                return 0
            }
        }
        """
    ]
}
