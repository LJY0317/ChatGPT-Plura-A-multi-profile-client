import XCTest
@testable import ChatGPT_Plura___A_multi_profile_client

final class RemoteMcpElicitationTests: XCTestCase {
    func testParsesTypedFormSchema() throws {
        let prompt = try XCTUnwrap(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "form",
            "message": "Choose deployment settings",
            "requestedSchema": [
                "type": "object",
                "required": ["email", "retries", "enabled", "region", "features"],
                "properties": [
                    "email": [
                        "type": "string",
                        "title": "Email",
                        "format": "email",
                        "minLength": 3,
                        "maxLength": 120,
                        "default": "a@b.co"
                    ],
                    "retries": [
                        "type": "integer",
                        "title": "Retries",
                        "minimum": 1,
                        "maximum": 5,
                        "default": 3
                    ],
                    "threshold": [
                        "type": "number",
                        "minimum": 0.0,
                        "maximum": 1.0,
                        "default": 0.75
                    ],
                    "enabled": [
                        "type": "boolean",
                        "default": true
                    ],
                    "region": [
                        "type": "string",
                        "oneOf": [
                            ["const": "kr", "title": "Korea"],
                            ["const": "us", "title": "United States"]
                        ],
                        "default": "kr"
                    ],
                    "features": [
                        "type": "array",
                        "items": [
                            "anyOf": [
                                ["const": "logs", "title": "Logs"],
                                ["const": "metrics", "title": "Metrics"]
                            ]
                        ],
                        "minItems": 1,
                        "maxItems": 2,
                        "default": ["logs"]
                    ]
                ]
            ]
        ]))

        XCTAssertEqual(prompt.serverName, "example-mcp")
        XCTAssertEqual(prompt.message, "Choose deployment settings")
        XCTAssertEqual(prompt.fields.count, 6)

        let fields = Dictionary(uniqueKeysWithValues: prompt.fields.map { ($0.key, $0) })

        let email = try XCTUnwrap(fields["email"])
        XCTAssertTrue(email.required)
        XCTAssertEqual(email.defaultValue, .string("a@b.co"))
        XCTAssertEqual(email.kind, .string(format: "email", minLength: 3, maxLength: 120))

        let retries = try XCTUnwrap(fields["retries"])
        XCTAssertEqual(retries.defaultValue, .integer(3))
        XCTAssertEqual(retries.kind, .number(integer: true, minimum: 1, maximum: 5))

        let threshold = try XCTUnwrap(fields["threshold"])
        XCTAssertFalse(threshold.required)
        XCTAssertEqual(threshold.defaultValue, .number(0.75))

        let enabled = try XCTUnwrap(fields["enabled"])
        XCTAssertEqual(enabled.kind, .boolean)
        XCTAssertEqual(enabled.defaultValue, .boolean(true))

        let region = try XCTUnwrap(fields["region"])
        XCTAssertEqual(
            region.kind,
            .singleSelect([
                .init(value: "kr", label: "Korea"),
                .init(value: "us", label: "United States")
            ])
        )

        let features = try XCTUnwrap(fields["features"])
        XCTAssertEqual(
            features.kind,
            .multiSelect([
                .init(value: "logs", label: "Logs"),
                .init(value: "metrics", label: "Metrics")
            ], minItems: 1, maxItems: 2)
        )
        XCTAssertEqual(features.defaultValue, .strings(["logs"]))
    }

    func testParsesLegacyNamedAndUntitledEnums() throws {
        let prompt = try XCTUnwrap(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "form",
            "message": "Pick values",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "color": [
                        "type": "string",
                        "enum": ["r", "g"],
                        "enumNames": ["Red", "Green"]
                    ],
                    "tags": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["one", "two"]]
                    ]
                ]
            ]
        ]))

        let fields = Dictionary(uniqueKeysWithValues: prompt.fields.map { ($0.key, $0) })
        XCTAssertEqual(
            try XCTUnwrap(fields["color"]).kind,
            .singleSelect([
                .init(value: "r", label: "Red"),
                .init(value: "g", label: "Green")
            ])
        )
        XCTAssertEqual(
            try XCTUnwrap(fields["tags"]).kind,
            .multiSelect([
                .init(value: "one", label: "one"),
                .init(value: "two", label: "two")
            ], minItems: nil, maxItems: nil)
        )
    }

    func testRejectsUnsupportedModesAndMalformedSchemas() {
        XCTAssertNil(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "url",
            "message": "Open this URL",
            "url": "https://example.com"
        ]))

        XCTAssertNil(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "form",
            "message": "Bad enum",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "choice": ["type": "string", "enum": ["same", "same"]]
                ]
            ]
        ]))

        XCTAssertNil(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "form",
            "message": "Bad default",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "count": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 3,
                        "default": 5
                    ]
                ]
            ]
        ]))

        XCTAssertNil(RemoteMcpElicitationPrompt(params: [
            "serverName": "example-mcp",
            "threadId": "thread-1",
            "mode": "form",
            "message": "Wrong primitive default type",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean", "default": 1]
                ]
            ]
        ]))
    }

    func testTypedValuesProduceJSONCompatibleValues() throws {
        XCTAssertEqual(RemoteMcpElicitationValue.string("hello").jsonValue as? String, "hello")
        XCTAssertEqual(RemoteMcpElicitationValue.integer(4).jsonValue as? Int, 4)
        XCTAssertEqual(RemoteMcpElicitationValue.number(0.5).jsonValue as? Double, 0.5)
        XCTAssertEqual(RemoteMcpElicitationValue.boolean(true).jsonValue as? Bool, true)
        XCTAssertEqual(RemoteMcpElicitationValue.strings(["a", "b"]).jsonValue as? [String], ["a", "b"])
    }
}
