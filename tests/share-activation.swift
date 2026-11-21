import Foundation
import UniformTypeIdentifiers

let url = URL(fileURLWithPath: "Paperboy/ShareExtension/Info.plist")
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
let extensionInfo = plist["NSExtension"] as! [String: Any]
let attributes = extensionInfo["NSExtensionAttributes"] as! [String: Any]
let rule = attributes["NSExtensionActivationRule"] as! String
let predicate = NSPredicate(format: rule)
for (type, expected) in [
    ("com.adobe.pdf", true), ("public.url", true), ("public.plain-text", true), ("com.apple.property-list", true), ("public.png", false),
] {
    let item: [String: Any] = ["extensionItems": [["attachments": [["registeredTypeIdentifiers": [type]]]]]]
    let actual = predicate.evaluate(with: item)
    print(type, actual)
    precondition(actual == expected, "Unexpected activation match for \(type)")
}

let mainPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Paperboy/Info.plist")), format: nil) as! [String: Any]
let documentTypes = mainPlist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
precondition(documentTypes.contains { ($0["LSItemContentTypes"] as? [String])?.contains("com.adobe.pdf") == true }, "Missing PDF document registration")
print("PDF Open In registration verified")
