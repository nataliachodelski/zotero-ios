//
//  AnnotationConverter.swift
//  Zotero
//
//  Created by Michal Rentka on 25.01.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

#if PDFENABLED

import CocoaLumberjackSwift
import PSPDFKit
import RealmSwift

struct AnnotationConverter {
    enum Kind {
        case export
        case zotero
    }

    private static var newlineExpression: NSRegularExpression? = {
        do {
            return try NSRegularExpression(pattern: #"(?<!\.)\s*[\n\r]+\s*"#)
        } catch let error {
            DDLogError("AnnotationConverter: can't create newline expression - \(error)")
            return nil
        }
    }()

    // MARK: - Helpers

    /// Creates sort index from annotation and bounding box.
    /// - parameter annotation: PSPDFKit annotation from which sort index is created
    /// - parameter boundingBox; Bounding box converted to screen coordinates.
    /// - returns: Sort index (5 places for page, 6 places for character offset, 5 places for y position)
    static func sortIndex(from annotation: PSPDFKit.Annotation, boundingBoxConverter: AnnotationBoundingBoxConverter?) -> String {
        let rect: CGRect
        if annotation is PSPDFKit.HighlightAnnotation {
            rect = annotation.rects?.first ?? annotation.boundingBox
        } else {
            rect = annotation.boundingBox
        }

        let textOffset = boundingBoxConverter?.textOffset(rect: rect, page: annotation.pageIndex) ?? 0
        let minY = boundingBoxConverter?.sortIndexMinY(rect: rect, page: annotation.pageIndex).flatMap({ Int(round($0)) }) ?? 0
        return self.sortIndex(pageIndex: annotation.pageIndex, textOffset: textOffset, minY: minY)
    }

    static func sortIndex(pageIndex: PageIndex, textOffset: Int, minY: Int) -> String {
        return String(format: "%05d|%06d|%05d", pageIndex, textOffset, minY)
    }

    // MARK: - PSPDFKit -> Zotero

    /// Create Zotero annotation from existing PSPDFKit annotation.
    /// - parameter annotation: PSPDFKit annotation.
    /// - parameter color: Base color of annotation (can differ from current `PSPDPFKit.Annotation.color`)
    /// - parameter library: Library where annotation is stored.
    /// - parameter username: Username of current user.
    /// - parameter displayName: Display name of current user.
    /// - parameter boundingBoxConverter: Converts rects from pdf coordinate space.
    /// - returns: Matching Zotero annotation.
    static func annotation(from annotation: PSPDFKit.Annotation, color: String, library: Library, username: String, displayName: String, boundingBoxConverter: AnnotationBoundingBoxConverter?) -> DocumentAnnotation? {
        guard let document = annotation.document, AnnotationsConfig.supported.contains(annotation.type) else { return nil }

        let key = annotation.key ?? annotation.uuid
        let page = Int(annotation.pageIndex)
        let pageLabel = document.pageLabelForPage(at: annotation.pageIndex, substituteWithPlainLabel: false) ?? "\(annotation.pageIndex + 1)"
        let isAuthor = annotation.user == displayName || annotation.user == username
        let comment = annotation.contents.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) ?? ""
        let sortIndex = self.sortIndex(from: annotation, boundingBoxConverter: boundingBoxConverter)
        let date = Date()

        let author: String
        if isAuthor {
            author = self.createName(from: displayName, username: username)
        } else {
            author = annotation.user ?? L10n.unknown
        }

        let type: AnnotationType
        let rects: [CGRect]
        let text: String?
        let paths: [[CGPoint]]
        let lineWidth: CGFloat?

        if let annotation = annotation as? PSPDFKit.NoteAnnotation {
            type = .note
            rects = [CGRect(origin: annotation.boundingBox.origin.rounded(to: 3), size: AnnotationsConfig.noteAnnotationSize)]
            text = nil
            paths = []
            lineWidth = nil
        } else if let annotation = annotation as? PSPDFKit.HighlightAnnotation {
            type = .highlight
            rects = (annotation.rects ?? [annotation.boundingBox]).map({ $0.rounded(to: 3) })
            text = self.removeNewlines(from: annotation.markedUpString)
            paths = []
            lineWidth = nil
        } else if let annotation = annotation as? PSPDFKit.SquareAnnotation {
            type = .image
            rects = [annotation.boundingBox.rounded(to: 3)]
            text = nil
            paths = []
            lineWidth = nil
        } else if let annotation = annotation as? PSPDFKit.InkAnnotation {
            type = .ink
            rects = []
            text = nil
            paths = annotation.lines.flatMap({ lines -> [[CGPoint]] in
                return lines.map({ group in
                    return group.map({ $0.location.rounded(to: 3) })
                })
            }) ?? []
            lineWidth = annotation.lineWidth
        } else {
            return nil
        }

        return DocumentAnnotation(key: key, type: type, page: page, pageLabel: pageLabel, rects: rects, paths: paths, lineWidth: lineWidth, author: author, isAuthor: isAuthor, color: color,
                                  comment: comment, text: text, sortIndex: sortIndex, dateModified: date)
    }

    static func removeNewlines(from string: String) -> String {
        guard let expression = self.newlineExpression else { return string }

        let matches = expression.matches(in: string, options: [], range: NSRange(string.startIndex..., in: string))

        var newString = string
        for match in matches.reversed() {
            guard let range = Range(match.range, in: newString) else { continue }
            newString = newString.replacingCharacters(in: range, with: " ")
        }
        return newString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func createName(from displayName: String, username: String) -> String {
        if !displayName.isEmpty {
            return displayName
        }
        if !username.isEmpty {
            return username
        }
        return L10n.unknown
    }

    // MARK: - Zotero -> PSPDFKit

    /// Converts Zotero annotations to actual document (PSPDFKit) annotations with custom flags.
    /// - parameter zoteroAnnotations: Annotations to convert.
    /// - returns: Array of PSPDFKit annotations that can be added to document.
    static func annotations(from items: Results<RItem>, type: Kind = .zotero, interfaceStyle: UIUserInterfaceStyle, currentUserId: Int, library: Library, displayName: String, username: String,
                            boundingBoxConverter: AnnotationBoundingBoxConverter) -> [PSPDFKit.Annotation] {
        return items.map({ item in
            return self.annotation(from: DatabaseAnnotation(item: item), type: type, interfaceStyle: interfaceStyle, currentUserId: currentUserId, library: library, displayName: displayName,
                                   username: username, boundingBoxConverter: boundingBoxConverter)
        })
    }

    static func annotation(from zoteroAnnotation: DatabaseAnnotation, type: Kind, interfaceStyle: UIUserInterfaceStyle, currentUserId: Int, library: Library, displayName: String, username: String,
                           boundingBoxConverter: AnnotationBoundingBoxConverter) -> PSPDFKit.Annotation {
        let (color, alpha, blendMode) = AnnotationColorGenerator.color(from: UIColor(hex: zoteroAnnotation.color), isHighlight: (zoteroAnnotation.type == .highlight), userInterfaceStyle: interfaceStyle)
        let annotation: PSPDFKit.Annotation

        switch zoteroAnnotation.type {
        case .image:
            annotation = self.areaAnnotation(from: zoteroAnnotation, type: type, color: color, boundingBoxConverter: boundingBoxConverter)
        case .highlight:
            annotation = self.highlightAnnotation(from: zoteroAnnotation, type: type, color: color, alpha: alpha, boundingBoxConverter: boundingBoxConverter)
        case .note:
            annotation = self.noteAnnotation(from: zoteroAnnotation, type: type, color: color, boundingBoxConverter: boundingBoxConverter)
        case .ink:
            annotation = self.inkAnnotation(from: zoteroAnnotation, type: type, color: color, boundingBoxConverter: boundingBoxConverter)
        }

        switch type {
        case .export:
            annotation.customData = nil

        case .zotero:
            annotation.customData = [AnnotationsConfig.baseColorKey: zoteroAnnotation.color,
                                     AnnotationsConfig.keyKey: zoteroAnnotation.key]

            if zoteroAnnotation.editability(currentUserId: currentUserId, library: library) != .editable {
                annotation.flags.update(with: .readOnly)
            }
        }

        if let blendMode = blendMode {
            annotation.blendMode = blendMode
        }

        annotation.pageIndex = UInt(zoteroAnnotation.page)
        annotation.contents = zoteroAnnotation.comment
        annotation.user = zoteroAnnotation.author(displayName: displayName, username: username)
        annotation.name = "Zotero-\(zoteroAnnotation.key)"

        return annotation
    }

    /// Creates corresponding `SquareAnnotation`.
    /// - parameter annotation: Zotero annotation.
    private static func areaAnnotation(from annotation: Annotation, type: Kind, color: UIColor, boundingBoxConverter: AnnotationBoundingBoxConverter) -> PSPDFKit.SquareAnnotation {
        let square: PSPDFKit.SquareAnnotation
        switch type {
        case .export:
            square = PSPDFKit.SquareAnnotation()
        case .zotero:
            square = SquareAnnotation()
        }

        square.boundingBox = annotation.boundingBox(boundingBoxConverter: boundingBoxConverter).rounded(to: 3)
        square.borderColor = color
        square.lineWidth = AnnotationsConfig.imageAnnotationLineWidth

        return square
    }

    /// Creates corresponding `HighlightAnnotation`.
    /// - parameter annotation: Zotero annotation.
    private static func highlightAnnotation(from annotation: Annotation, type: Kind, color: UIColor, alpha: CGFloat, boundingBoxConverter: AnnotationBoundingBoxConverter) -> PSPDFKit.HighlightAnnotation {
        let highlight: PSPDFKit.HighlightAnnotation
        switch type {
        case .export:
            highlight = PSPDFKit.HighlightAnnotation()
        case .zotero:
            highlight = HighlightAnnotation()
        }

        highlight.boundingBox = annotation.boundingBox(boundingBoxConverter: boundingBoxConverter).rounded(to: 3)
        highlight.rects = annotation.rects(boundingBoxConverter: boundingBoxConverter).map({ $0.rounded(to: 3) })
        highlight.color = color
        highlight.alpha = alpha

        return highlight
    }

    /// Creates corresponding `NoteAnnotation`.
    /// - parameter annotation: Zotero annotation.
    private static func noteAnnotation(from annotation: Annotation, type: Kind, color: UIColor, boundingBoxConverter: AnnotationBoundingBoxConverter) -> PSPDFKit.NoteAnnotation {
        let note: PSPDFKit.NoteAnnotation
        switch type {
        case .export:
            note = PSPDFKit.NoteAnnotation(contents: annotation.comment)
        case .zotero:
            note = NoteAnnotation(contents: annotation.comment)
        }

        let boundingBox = annotation.boundingBox(boundingBoxConverter: boundingBoxConverter).rounded(to: 3)
        note.boundingBox = CGRect(origin: boundingBox.origin, size: AnnotationsConfig.noteAnnotationSize)
        note.borderStyle = .dashed
        note.color = color

        return note
    }

    private static func inkAnnotation(from annotation: Annotation, type: Kind, color: UIColor, boundingBoxConverter: AnnotationBoundingBoxConverter) -> PSPDFKit.InkAnnotation {
        let lines = annotation.paths(boundingBoxConverter: boundingBoxConverter).map({ group in
            return group.map({ DrawingPoint(cgPoint: $0) })
        })
        let ink = PSPDFKit.InkAnnotation(lines: lines)
        ink.color = color
        ink.lineWidth = annotation.lineWidth ?? 1
        return ink
    }
}

extension RItem {
    fileprivate func fieldValue(for key: String) -> String? {
        let value = self.fields.filter(.key(key)).first?.value
        if value == nil {
            DDLogError("Annotation: missing value for `\(key)`")
        }
        return value
    }
}

#endif
