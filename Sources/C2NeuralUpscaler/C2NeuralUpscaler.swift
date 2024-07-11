//
//  NeuralImageUpscaler.swift
//
//
//  Created by niall. on 1/09/23.
//

import Foundation
import Vision
import VideoToolbox
import UniformTypeIdentifiers
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import C2PlatformIndependentImage

/**
    Uses the neural engine, and real-ESRGAN to upscale a PlatformIndependentImage.
    No support for iOS 15; every device that can actually handle the upscaling already supports iOS 16. (A12B and above)
    No support for macOS Monterey because Cellulose doesn't support macOS Monterey anyway.
 */
@available(iOS 15.0, *)
@available(macOS 12.0, *)
@available(visionOS 1, *)
public final class C2NeuralImageUpscaler: ObservableObject {
    
    internal static let CHUNK_CACHE_BASE = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cellulose-chunkcache", conformingTo: .folder)
    internal static let INPUT_CHUNK_SIZE = CGSize(width: 512, height: 512)
    public static let OUTPUT_UPSCALING_FACTOR = 4 // 512x512 -> 2048x2048
    private let image: CGImage
    private let originalImageSize: CGSize
    private let cacheBase: URL
    private let config: MLModelConfiguration
    private var model: VNCoreMLModel?
    
    // UI State.
    @MainActor @Published var totalImageChunks: Int = 0
    @MainActor @Published var currentImageChunk: Int = 0
    @MainActor @Published var state: NeuralImageUpscalerState = .idle
    
    /**
        Represents current state of upscaling operation.
    */
    public enum NeuralImageUpscalerState {
        case idle
        /// Includes current chunk, and total chunks for showing progress.
        case upscaling(currentChunk: Int, totalChunks: Int)
        case stitching
        case complete
    }
    
    public enum NeuralImageUpscalerError: Error {
        /// Unknown upscaler error. Original exception will be passed if available.
        case unknownError(Error?)
        case cacheStorageFailure
        case failedToCrop
        case stitchingFailed
        case upscalerFailure
    }
    
    /**
        Create a new upscaler from a CelluloseImageKit C2PlatformIndependentImage
        - Parameter forImage: Image to upscale and clean up.
     */
    public init(forImage image: C2PlatformIndependentImage) {
        guard let cgimage = image.toCgImage()
        else {
            // TODO: make this init optional, and return nil if this fails.
            fatalError("Could not retrieve cgImage!")
        }
        
        self.image = cgimage
        // we don't use C2PlatformIndependentImage's .size here; that's measured in points and
        // is designed for UI layout purposes; it may not necessarily represent the actual
        // bitmap size, unlike CGImage width & height, which will give us actual pixelcounts.
        self.originalImageSize = .init(width: cgimage.width, height: cgimage.height)
        self.cacheBase = C2NeuralImageUpscaler.CHUNK_CACHE_BASE.appendingPathComponent(UUID().uuidString, conformingTo: .folder)
        self.config = MLModelConfiguration()
        self.model = nil
        self.setComputeUnits(self.config)
    }
    
    /**
        Create a new upscaler using a CGImage.
        - Parameter forCGImage: CGImage to upscale and clean up.
     */
    public init(forCGImage cgimage: CGImage) {
        self.image = cgimage
        // we don't use C2PlatformIndependentImage's .size here; that's measured in points and
        // is designed for UI layout purposes; it may not necessarily represent the actual
        // bitmap size, unlike CGImage width & height, which will give us actual pixelcounts.
        self.originalImageSize = .init(width: cgimage.width, height: cgimage.height)
        self.cacheBase = C2NeuralImageUpscaler.CHUNK_CACHE_BASE.appendingPathComponent(UUID().uuidString, conformingTo: .folder)
        self.config = MLModelConfiguration()
        self.model = nil
        self.setComputeUnits(self.config)
    }
    
    deinit {
        Logger.neuralImageUpscaler.debug("Deinit!")
        self.cleanup()
    }
    
    /**
        Remove cached chunks and other miscellaneous files.
        Should be called during deinit.
     */
    private func cleanup() {
        Logger.neuralImageUpscaler.debug("Cleaning up chunk cache...")
        
        guard let folderContents = try? FileManager.default.contentsOfDirectory(at: self.cacheBase, includingPropertiesForKeys: nil)
        else {
            Logger.neuralImageUpscaler.warning("Could not get contents of cache directory \(self.cacheBase)! Cleanup is the systems problem now.")
            return
        }
        
        for filePath in folderContents {
            try? FileManager.default.removeItem(at: filePath)
        }
    }

    
    /**
        Neural upscale an image.
        - Returns: New C2PlatformIndependentImage if successful,  otherwise, an error.
    */
    public func upscale() -> Result<C2PlatformIndependentImage, NeuralImageUpscalerError> {
        do {
            var xMult = 0, yMult = 0, currentChunk = 0
            var chunks: [UUID] = []
            
            
            let chunkCountH = Int(ceil(self.originalImageSize.width
                                       / C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width))
            let chunkCountV = Int(ceil(self.originalImageSize.height
                                       / C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.height))
            let chunkCount = chunkCountH * chunkCountV
            
            DispatchQueue.main.async {
                self.state = .upscaling(currentChunk: currentChunk, totalChunks: chunkCountH * chunkCountV)
            }
            
            while yMult < chunkCountV {
                while xMult < chunkCountH {
                    Logger.neuralImageUpscaler.debug("Creating horiz chunk with x offset mult \(xMult), y offset mult \(yMult).")
                    
                    let topLeft = CGPoint(x: C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width * CGFloat(xMult),
                                          y: C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.height * CGFloat(yMult))
                    let rawChunk = self.createImageChunk(topLeft: topLeft)
                    chunks.append(try self.upscaleChunk(chunk: rawChunk))
                    
                    xMult += 1 ; currentChunk += 1
                    DispatchQueue.main.async {self.state = .upscaling(currentChunk: currentChunk,
                                                                      totalChunks: chunkCount) }
                    
                }
                xMult = 0
                yMult += 1
            }
            
            DispatchQueue.main.async {
                self.state = .stitching
            }
        
            let output = try self.stitchImage(chunkIdentifiers: chunks)
            
            DispatchQueue.main.async {
                self.state = .complete
            }
            
            return .success(output)
        } catch(let e) {
            Logger.neuralImageUpscaler.error("Process failed with error. (\(e.localizedDescription)).")
            return .failure(e as? NeuralImageUpscalerError ?? .unknownError(e))
        }
    }

    
    /**
        Sets up the best compute unit setup for the upscaler MLModel.
        Attempts to use the neural engine if possible.
     
        - Parameter configuration: An MLModelConfiguration object to apply changes to.
     
        A no-op on older platforms, where the compute units will be left as is (all).
    */
    private func setComputeUnits(_ configuration: MLModelConfiguration){
        #if os(iOS) || os(visionOS)
        if #available(iOS 16.0, *) {
            configuration.computeUnits = .cpuAndNeuralEngine
        }
        #elseif os(visionOS)
        configuration.computeUnits = .cpuAndNeuralEngine
        #elseif os(macOS)
        if #available(macOS 13.0, *) {
            configuration.computeUnits = .cpuAndNeuralEngine
        }
        #endif
    }
    
    
    /**
        Create a chunk from the base image.
     
        - Parameter topLeft: Top left CGPoint to create image chunk from. (i.e. 0, 0 for first chunk from top left of image)
        - Returns: New `CGImage` object containing only the cropped chunk.
     */
    private func createImageChunk(topLeft: CGPoint) -> CGImage {
        let wMax = C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width
        let wActual = self.originalImageSize.width - topLeft.x
        
        let hMax = C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.height
        let hActual = self.originalImageSize.height - topLeft.y
        
        let width = min(wActual, wMax)
        let height = min(hActual, hMax)
        
        let chunkRect = CGRect(x: topLeft.x,
                              y: topLeft.y,
                              width: width,
                              height: height)
        
        let cropped = self.image.cropping(to: chunkRect)!
        
        let ctx = CGContext(data: nil,
                            width: Int(C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width),
                            height: Int(C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.height),
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        
        ctx.draw(cropped, in: .init(x: 0,
                                    y: ctx.height - Int(min(hActual, hMax)),
                                    width: cropped.width,
                                    height: cropped.height))
        
        return ctx.makeImage()!
        
    }
    
    /**
        Ensure the existence of the chunk storage cache for this upscaler.
        Will attempt to create it if it doesn't exist.
        
        Crashes if it can't be created. This should probably change in the future.
    */
    @inline(__always) private func ensureChunkDirectory() {
        if !FileManager.default.fileExists(atPath: self.cacheBase.path) {
            Logger.neuralImageUpscaler.debug("Creating temporary chunk storage directory at \(self.cacheBase).")
            try! FileManager.default.createDirectory(at: self.cacheBase,
                                                withIntermediateDirectories: true)
        }
    }
    
    /**
        Stores a chunk in a temporary cache directory to save memory.
     
        - Parameter chunk: CGImage chunk to save.
        - Returns: UUID used to retrieve chunk from `self.retrieveChunk`, or nil if saving failed.
     */
    private func storeChunk(_ chunk: CGImage) -> UUID? {
        
        self.ensureChunkDirectory()
        
        let identifier = UUID()
        let outputURL = self.cacheBase.appendingPathComponent(identifier.uuidString,
                                                              conformingTo: .png)
        
        func writeData(to output: URL) throws {
            guard let data = chunk.asPngData
            else {
                Logger.neuralImageUpscaler.critical("Failed to convert CGImage to png data for chunk storage!")
                throw NeuralImageUpscalerError.cacheStorageFailure
            }
            
            try data.write(to: output)
        }
        
        do {
            try writeData(to: outputURL)
            return identifier
        } catch(let e) {
            Logger.neuralImageUpscaler.critical("Could not save image chunk to cache! \(e.localizedDescription)")
            return nil
        }
    }
    
    /**
        Load stored chunk from disk, and remove it from disk.
        - Parameter withID: UUID identifying chunk
        - Returns: CGImage if chunk can be loaded, or nil if not.
     */
    private func retrieveChunk(withID id: UUID) -> CGImage? {
        
        self.ensureChunkDirectory()
        
        let inputURL = self.cacheBase.appendingPathComponent(id.uuidString,
                                                             conformingTo: .png)
        
        func readData(from input: URL) -> CGImage? {
            guard let data = try? Data(contentsOf: input)
            else {
                return nil
            }
            let provider = CGDataProvider(data: data as CFData)
            return CGImage(pngDataProviderSource: provider!,
                           decode: nil,
                           shouldInterpolate: false,
                           intent: .absoluteColorimetric)
        }
        
        if let chunk = readData(from: inputURL) {
            try? FileManager.default.removeItem(at: inputURL)
            return chunk
        }
        
        Logger.neuralImageUpscaler.critical("Could not read image chunk from cache!")
        return nil
    }
    
    /**
        Upscale a CGImage chunk using Real ESRGAN.
        - Parameter chunk: CGImage to be upscaled. For best results, it's dimensions should be `<= 512x512`
        - Returns: New upscaled CGImage chunk (4x scale factor)
     */
    private func upscaleChunk(chunk: CGImage) throws -> UUID {
        Logger.neuralImageUpscaler.debug("Upscaling chunk...")
        
        if self.model == nil {
            Logger.neuralImageUpscaler.debug("CoreML model is unset. Loading model for upscaling session.")
            self.model = try! VNCoreMLModel(for: RealEsrgan(configuration: self.config).model)
        }
        
        let m = self.model!
        let request = VNCoreMLRequest(model: m)
        let handler = VNImageRequestHandler(cgImage: chunk, options: [:])
        
        try? handler.perform([request])
        guard let result = request.results?.first as? VNPixelBufferObservation
        else {
            Logger.neuralImageUpscaler.critical("Failed to upscale chunk!")
            throw NeuralImageUpscalerError.upscalerFailure
        }
        
        let outputBuffer = result.pixelBuffer
        var outputImage: CGImage?
        
        // what a lovely function with a nice concise name :)
        VTCreateCGImageFromCVPixelBuffer(outputBuffer, options: nil, imageOut: &outputImage)
        
        guard let outputImage = outputImage
        else {
            Logger.neuralImageUpscaler.critical("Could not construct CGImage from upscaled pixelbuffer!")
            throw NeuralImageUpscalerError.upscalerFailure
        }
        
        guard let storageIdentifier = self.storeChunk(outputImage)
        else {
            throw NeuralImageUpscalerError.cacheStorageFailure
        }
        
        return storageIdentifier
    }
    
    /**
        Stitch image from upscaled chunks.
        - Parameter chunkIdentifiers: UUID array identifying chunks in storage.
        - Returns: New C2PlatformIndependentImage containing stitched upscaled image.
     */
    private func stitchImage(chunkIdentifiers: [UUID]) throws -> C2PlatformIndependentImage {
        let individualChunkSize = CGSize(width: C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width *
                                                CGFloat(C2NeuralImageUpscaler.OUTPUT_UPSCALING_FACTOR),
                                         height: C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.height *
                                                 CGFloat(C2NeuralImageUpscaler.OUTPUT_UPSCALING_FACTOR))
        
        let horizontalCount = Int(ceil(self.originalImageSize.width /
                                       C2NeuralImageUpscaler.INPUT_CHUNK_SIZE.width))
        
        let outputWidth = Int(self.originalImageSize.width) * C2NeuralImageUpscaler.OUTPUT_UPSCALING_FACTOR
        let outputHeight = Int(self.originalImageSize.height) * C2NeuralImageUpscaler.OUTPUT_UPSCALING_FACTOR
        
        // this is certainly something.
        let colorSpace: CGColorSpace = .init(name: CGColorSpace.sRGB)!
        
        // i hate this API i hate this API i hate this API i hate this API i hate this API
        guard let outputCtx = CGContext(data: nil,
                                  width: outputWidth , height: outputHeight,
                                  bitsPerComponent: 8,
                                  // 0 will calculate bytes per row automatically.
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  // We expect RGBA or RGB input, but we don't actually need the transparency
                                  // for page images, so discard any alpha channel from image.
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            throw NeuralImageUpscalerError.stitchingFailed
        }
        
        var vertOffset = 0
        for chunkIndex in chunkIdentifiers.indices {
            if chunkIndex != 0 && chunkIndex % horizontalCount == 0 {
                Logger.neuralImageUpscaler.debug("chunkIndex % rows == 0; increasing y offset.")
                vertOffset += 1
            }
            
            Logger.neuralImageUpscaler.debug("Drawing chunk (idx: \(chunkIndex)) at x\(chunkIndex % horizontalCount), y\(vertOffset)")
            
            guard let chunk = self.retrieveChunk(withID: chunkIdentifiers[chunkIndex])
            else {
                Logger.neuralImageUpscaler.critical("Failed to retrieve chunk \(chunkIndex)!")
                throw NeuralImageUpscalerError.cacheStorageFailure
            }
            
            // rect calculation. because we're not using UIKit or SwiftUI, the coordinate system's
            // origin point is at the bottom left of the image, with positive Y values going upwards.
            let drawRectX = individualChunkSize.width * CGFloat(chunkIndex % horizontalCount)
            // - height so we start at bottom of image. because fuck consistency, UIKit just had to be
            // different so now this conversion feels alien.
            let drawRectY = CGFloat(outputCtx.height) - (individualChunkSize.height * CGFloat(vertOffset)) - CGFloat(chunk.height)
            
            
            outputCtx.draw(chunk, in: .init(x: drawRectX,
                                            y: drawRectY,
                                            width: individualChunkSize.width,
                                            height: individualChunkSize.height))
        }
        
        guard let output = outputCtx.makeImage()
        else {
            throw NeuralImageUpscalerError.stitchingFailed
        }
        
        // TODO: C2PlatformIndependentImage should have a CGImage initalizer.
        #if os(macOS)
        let image = NSImage(cgImage: output, size: .init(width: output.width, height: output.height))
        return C2PlatformIndependentImage(fromPlatformSpecificImage: image)
        #elseif os(iOS) || os(visionOS)
        let image = UIImage(cgImage: output)
        return C2PlatformIndependentImage(fromPlatformSpecificImage: image)
        #else
        fatalError("Unimplemented platform for image stitching!")
        #endif
    }
    
    
}

internal extension Logger {
    static let neuralImageUpscaler = Logger(subsystem: "C2NeuralUpscaler",
                                            category: "neuralImageUpscaler")
}

private extension CGImage {
    var asPngData: Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
