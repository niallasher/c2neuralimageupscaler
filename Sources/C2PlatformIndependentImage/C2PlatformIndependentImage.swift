//
//  PlatformIndependentImage.swift
//
//
//  Created by niall. on 1/09/23.
//

import Foundation
import OSLog
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

public enum PlatformIndependentImageOutputType {
    case png
    case jpeg
}

/**
    PlatformIndependentImage wraps a natively available image type (type decided based on compilation target; iOS, visionOS, macOS)
    If building for macOS, self.nativeImage will be an `NSImage`, while building for other platforms (supports visionOS & iOS/iPadOS), a `UIImage` will be present instead.
 
    Provides wrapper functions for some common operations for the native image type. (e.g. getting a CGImage from it, resizing it)
*/
@available(iOS 15.0, *)
@available(macOS 12.0, *)
@available(visionOS 1.0, *)
public final class C2PlatformIndependentImage: Identifiable, Equatable {
    public let id = UUID()
    
    /// The default compression quality for JPEG images. Used if a compression quality is not specified when calling
    /// `getDataRepresentation(for: _, compressionQuality: _?)`or `convertDataTo(format: _, data: _, compressionQuality: _?)`
    static let DEFAULT_COMPRESSION_QUALITY: CGFloat = 1.0
    
    /**
        Attempts to create a platform indepentent image from a Data object.
        - Parameter fromPlatformSpecificImage: NSImage or UIImage.
    */
    public init?(fromData data: Data) {
        #if os(iOS) || os(visionOS)
        guard let _image = UIImage(data: data)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #elseif os(macOS)
        guard let _image = NSImage(data: data)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #else
        fatalError("init?(fromData:_) not implemented on current platform!")
        #endif
    }
    
    /**
        Attempts to create a platform independent image for a system image (e.g.. an SF Symbol)
    */
    public init?(forSystemImage systemName: String) {
        #if os(iOS) || os(visionOS)
        guard let _image = UIImage(systemName: systemName)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #elseif os(macOS)
        guard let _image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #else
        fatalError("init?(forSystemImage:_) unimplemented on current platform!")
        #endif
    }
    
    /**
        Attempts to create a platform independent image from a resource in the asset catalogue
    */
    public init?(forAssetCatalogueImageNamed name: String) {
        #if os(iOS) || os(visionOS)
        guard let _image = UIImage(named: name)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #elseif os(macOS)
        guard let _image = NSImage(named: name)
        else {
            return nil
        }
        
        self.nativeImage = _image
        #endif
    }
    
    /**
        Attempts to create a platform independent image from a CGImage
    */
    public init?(fromCgImage cgImage: CGImage) {
        #if os(iOS) || os(visionOS)
        self.nativeImage = UIImage(cgImage: cgImage)
        #elseif os(macOS)
        self.nativeImage = NSImage(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
        #else
        fatalError("Initalizer init?(fromCgImage:_) unimplemented on current platform!")
        #endif
    }
    
    #if os(iOS) || os(visionOS)
    /**
        Creates a platform indepentent image from a platform specific image object (in this case, `UIImage`)
        - Parameter fromPlatformSpecificImage: UIImage.
    */
    public init(fromPlatformSpecificImage nativeImage: UIImage){
        self.nativeImage = nativeImage
    }
    #elseif os(macOS)
    /**
        Creates a platform indepentent image from a platform specific image object (in this case, `NSImage`)
        - Parameter fromPlatformSpecificImage: NSImage.
    */
    public init(fromPlatformSpecificImage image: NSImage){
        self.nativeImage = image
    }
    #endif
    
    #if os(iOS) || os(visionOS)
    /// Platform usable image object. Do not access directly from cross platform code! Use methods and variables on `self` instead.
    public let nativeImage: UIImage
    /// Size of the image. May not be in pixels depending on screen scale.
    public lazy var size: CGSize = self.nativeImage.size
    #elseif os(macOS)
    /// Platform usable image object. Do not access directly from cross platform code! Use methods and variables on `self` instead.
    public let nativeImage: NSImage
    /// Size of the image. May not be in pixels depending on screen scale.
    public lazy var size: CGSize = self.nativeImage.size
    #endif
    
    /**
        Returns a CGImage representation of the native image.
        - Returns: CGImage, or nil if no representation can be created.
     */
    public func toCgImage() -> CGImage? {
        #if os(iOS) || os(visionOS)
        return self.nativeImage.cgImage
        #elseif os(macOS)
        return self.nativeImage.cgImage(forProposedRect: nil,
                                        context: nil,
                                        hints: nil)
        #else
        fatalError("toCgImage() unimplemented on current platform!")
        #endif
    }
    
    /**
        Creates a copy of the image to binary data.
        - Parameter as: File type to output. One of PlatformSpecificImageOutputType
        - Returns: Data object if operation succeeded, otherwise nil.
            
        Does not guard or warn against things like losing the alpha channel from converting to JPEG,
        so make sure to check when you use it.
        Use sparingly; converting jpeg data to jpeg data with a low quality level will **rapidly** cause generation loss, and leave you with an awful looking image.
        Conversion to PNG is safe, but will incur size penalities. 99% of the time you should just use the format the image came in with, and only convert if it's not already a JPEG or PNG.
    */
    public func getDataRepresentation(as imageType: PlatformIndependentImageOutputType,
                               withCompressionQuality _compressionQuality: CGFloat? = nil) -> Data? {
        switch(imageType) {
            case .jpeg:
                return C2PlatformIndependentImage.getJpegDataRepresentation(forImage: self.nativeImage, withCompressionQuality: _compressionQuality)
            case .png:
                return C2PlatformIndependentImage.getPngDataRepresentation(forImage: self.nativeImage)
        }
    }
    
    
    #if os(iOS) || os(visionOS)
    private static func getJpegDataRepresentation(forImage image: UIImage,
                                                  withCompressionQuality _compressionQuality: CGFloat? = nil) -> Data? {
        
        let compressionQuality: CGFloat = _compressionQuality ?? C2PlatformIndependentImage.DEFAULT_COMPRESSION_QUALITY
        Logger.platformIndependentImage.info("Creating JPEG data representation of \(image)")
        guard let data = image.jpegData(compressionQuality: compressionQuality)
        else {
            Logger.platformIndependentImage.info("Failed to create JPEG data representation of \(image)!")
            return nil
        }
        return data
    }
    #elseif os(macOS)
    private static func getJpegDataRepresentation(forImage image: NSImage,
                                                  withCompressionQuality _compressionQuality: CGFloat? = nil) -> Data? {
        // TODO: implement compressionQuality for macOS PlatformIndependentImage
        Logger.platformIndependentImage.info("Creating JPEG data representation of \(image)")
        
        guard let tiffRep = image.tiffRepresentation
        else {
            Logger.platformIndependentImage.error("Could not get NSImage tiff representation")
            return nil
        }
        
        let rep = NSBitmapImageRep(data: tiffRep)
        
        // TODO: USE COMPRESSION QUALITY THAT WAS PASSED IN!
        guard let data = rep?.representation(using: .jpeg, properties: [.compressionFactor : 0])
        else {
            Logger.platformIndependentImage.error("Could not get JPEG representation from NSBitmapImageRep!")
            return nil
        }
        
        return data
    }
    #endif
    
    #if os(iOS) || os(visionOS)
    private static func getPngDataRepresentation(forImage image: UIImage) -> Data? {
        Logger.platformIndependentImage.info("Creating PNG data representation of \(image)")
        guard let data = image.pngData()
        else {
            Logger.platformIndependentImage.warning("Failed to create PNG data representation of \(image)")
            return nil
        }
        
        return data
    }
    #elseif os(macOS)
    private static func getPngDataRepresentation(forImage image: NSImage) -> Data? {
        Logger.platformIndependentImage.info("Creating PNG data representation of \(image)")
        
        guard let tiffRep = image.tiffRepresentation
        else {
            Logger.platformIndependentImage.error("Could not get NSImage tiff representation")
            return nil
        }
        
        let rep = NSBitmapImageRep(data: tiffRep)
        
        guard let data = rep?.representation(using: .png, properties: [:])
        else {
            Logger.platformIndependentImage.error("Could not get PNG representation from NSBitmapImageRep!")
            return nil
        }
        
        return data
    }
    #endif
    
    /**
        Create a new PlatformIndependentImage, containing an resized version of this instances image,
        fitting as neatly as possible **within** `fittingInto`, while maintaining aspect ratio.
     
        - Parameter fittingInto: The largest allowable CGSize. The image will be sized up to fill one axis.
     
        This function does not upscale; if `maxSize` is larger than the current image, it will be returned as-is.
     */
    public func resized(fittingInto maxSize: CGSize) -> C2PlatformIndependentImage? {
        // the target size is larger in both dimensions, so it would be
        // a waste of time to do anything here.
        if maxSize.width > self.size.width && maxSize.height > self.size.height {
            // we still want to return a new instance, not a reference to self,
            // so we'll duplicate the object.
            // (this is to keep things clear r.e. reference counts)
            return C2PlatformIndependentImage(fromPlatformSpecificImage: self.nativeImage)
        }
        
        let widthRatio  = maxSize.width  / size.width
        let heightRatio = maxSize.height / size.height
        
        // Figure out what our orientation is, and use that to form the rectangle
        var newSize: CGSize
        if(widthRatio > heightRatio) {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio, height: size.height * widthRatio)
        }
        
        // This is the rect that we've calculated out and this is what is actually used below
        let rect = CGRect(origin: .zero, size: newSize)
        
        // TODO: this should just be using CGImage
        #if os(iOS) || os(visionOS)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        self.nativeImage.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        if let newImage = newImage {
            return C2PlatformIndependentImage(fromPlatformSpecificImage: newImage)
        }
        
        return nil
        #elseif os(macOS)
        let destSize = NSMakeSize(newSize.width, newSize.height)
        let newImage = NSImage(size: destSize)
        
        newImage.lockFocus()
        self.nativeImage.draw(in: NSMakeRect(0, 0, destSize.width, destSize.height),
                              from: NSMakeRect(0, 0, self.size.width, self.size.height),
                              operation: NSCompositingOperation.sourceOver,
                              fraction: 1)
        newImage.unlockFocus()
        
        return C2PlatformIndependentImage(fromPlatformSpecificImage: newImage)
        #endif
    }
    
    static public func imageSizeFor(data: Data, fallbackSize: CGSize = .zero) -> CGSize {
        guard let image = C2PlatformIndependentImage(fromData: data)
        else {
            return fallbackSize
        }
        
        return image.size
    }
    
    /**
        Attempt to parse and convert image data to another format.
     
        - Parameter format: PlatformIndependentImageOutputType controlling the output format
        - Parameter data: Input data. If it's not an image, nil will be returned.
        - Parameter compressionQuality: (Optional) When creating a JPEG, if this is unspecified, `PlatformIndependentImage.DEFAULT_COMPRESSION_QUALITY` will be used instead. Ranges from 0 to 1.0, with 1.0 being full quality.
        - Returns: new Data object containing the image from `data` in the new format, or nil, if either `data` doesn't contain an image, or another failure occurs.
     
        Use sparingly; converting jpeg data to jpeg data with a low quality level will **rapidly** cause generation loss, and leave you with an awful looking image. Conversion to PNG is safe, but will incur size penalities.
        99% of the time you should just use the format the image came in with, and only convert if it's not already a JPEG or PNG.
     */
    static public func convertDataTo(format: PlatformIndependentImageOutputType, data: Data, compressionQuality: CGFloat? = nil) -> Data? {
        #if os(iOS) || os(visionOS)
        guard let image = UIImage(data: data)
        else {
            Logger.platformIndependentImage.warning("convertDataTo: Data object did not contain valid image data; UIImage could not be constructed. (\(data))")
            return nil
        }
        #elseif os(macOS)
        guard let image = NSImage(data: data)
        else {
            Logger.platformIndependentImage.warning("convertDataTo: Data object did not contain valid image data; NSImage could not be constructed. (\(data)")
            return nil
        }
        #else
        fatalError("convertDataTo(format:_, data:_, compressionQuality:_) not implemented on current platform!")
        #endif
        
        switch(format) {
            case .jpeg:
                return C2PlatformIndependentImage.getJpegDataRepresentation(forImage: image, withCompressionQuality: compressionQuality)
            case .png:
                return C2PlatformIndependentImage.getPngDataRepresentation(forImage: image)
        }
    }

    static public func ==(lhs: C2PlatformIndependentImage, rhs: C2PlatformIndependentImage) -> Bool {
        return lhs.id == rhs.id
    }
}


internal extension Logger {
    static let platformIndependentImage = Logger(subsystem: "CelluloseImageKit",category: "PlatformIndependentImage")
}
