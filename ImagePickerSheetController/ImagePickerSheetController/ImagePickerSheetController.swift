//
//  ImagePickerController.swift
//  ImagePickerSheet
//
//  Created by Laurin Brandner on 24/05/15.
//  Copyright (c) 2015 Laurin Brandner. All rights reserved.
//

import Foundation
import Photos

let previewInset: CGFloat = 5

/// The media type an instance of ImagePickerSheetController can display
public enum ImagePickerMediaType: Int {
    case image
    case video
    case imageAndVideo
    case none
}

@objc public protocol ImagePickerSheetControllerDelegate {
    
    @objc optional func controllerWillEnlargePreview(_ controller: ImagePickerSheetController)
    @objc optional func controllerDidEnlargePreview(_ controller: ImagePickerSheetController)
    
    @objc optional func controller(_ controller: ImagePickerSheetController, willSelectAsset asset: PHAsset)
    @objc optional func controller(_ controller: ImagePickerSheetController, didSelectAsset asset: PHAsset)
    
    @objc optional func controller(_ controller: ImagePickerSheetController, willDeselectAsset asset: PHAsset)
    @objc optional func controller(_ controller: ImagePickerSheetController, didDeselectAsset asset: PHAsset)
    
}

@available(iOS 9.0, *)
open class ImagePickerSheetController: UIViewController {
    
    open var baseFontName: String = "HelveticaNeue" {
        didSet {
            sheetController.labelBaseFontName = baseFontName
        }
    }
    open var tintColor: UIColor = .blue {
        didSet {
            sheetController.labelFontColor = tintColor
        }
    }
    
    fileprivate lazy var sheetController: SheetController = {
        let controller = SheetController(previewCollectionView: self.previewCollectionView)
        controller.displayPreview = self.mediaType != .none;
        controller.actionHandlingCallback = { [weak self] in
            self?.dismiss(animated: true, completion: { _ in
                // Possible retain cycle when action handlers hold a reference to the IPSC
                // Remove all actions to break it
                controller.removeAllActions()
            })
        }
        
        return controller
    }()
    
    var sheetCollectionView: UICollectionView {
        return sheetController.sheetCollectionView
    }
    
    fileprivate(set) lazy var previewCollectionView: PreviewCollectionView = {
        let collectionView = PreviewCollectionView()
        collectionView.accessibilityIdentifier = "ImagePickerSheetPreview"
        collectionView.backgroundColor = .clear
        collectionView.allowsMultipleSelection = true
        collectionView.imagePreviewLayout.sectionInset = UIEdgeInsets(top: previewInset, left: previewInset, bottom: previewInset, right: previewInset)
        collectionView.imagePreviewLayout.showsSupplementaryViews = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.register(PreviewCollectionViewCell.self, forCellWithReuseIdentifier: NSStringFromClass(PreviewCollectionViewCell.self))
        collectionView.register(PreviewSupplementaryView.self, forSupplementaryViewOfKind: UICollectionElementKindSectionHeader, withReuseIdentifier: NSStringFromClass(PreviewSupplementaryView.self))
        
        return collectionView
    }()
    
    fileprivate var supplementaryViews = [Int: PreviewSupplementaryView]()
    
    lazy var backgroundView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "ImagePickerSheetBackground"
        view.backgroundColor = UIColor(white: 0.0, alpha: 0.3961)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self.sheetController, action: #selector(SheetController.handleCancelAction)))
        
        return view
    }()
    
    open var delegate: ImagePickerSheetControllerDelegate?
    
    /// All the actions. The first action is shown at the top.
    open var actions: [ImagePickerAction] {
        return sheetController.actions
    }
    
    /// If set to true, after taping on preview image it enlarges
    public var enableEnlargedPreviews: Bool = true
    
    /// Maximum selection of images.
    open var maximumSelection: Int?
    
    /// The selected image assets
    public fileprivate(set) var selectedAssets:[PHAsset] = [] {
        didSet {
            sheetController.numberOfSelectedAssets = selectedAssets.count
        }
    }
    
    public var selectedImageAssets: [PHAsset] {
        return selectedAssets
    }
    
    /// The media type of the displayed assets
    open let mediaType: ImagePickerMediaType
    
    fileprivate var assets: [PHAsset] = []
    
    fileprivate lazy var requestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        
        return options
    }()
    
    fileprivate lazy var imageManager: PHCachingImageManager? = {
        if self.mediaType == .none {
            return nil
        }
        
        return PHCachingImageManager()
    }()
    
    /// Whether the image preview has been elarged. This is the case when at least once
    /// image has been selected.
    public fileprivate(set) var enlargedPreviews = false
    
    fileprivate let minimumPreviewHeight: CGFloat = 129
    fileprivate var maximumPreviewHeight: CGFloat = 129
    
    fileprivate var previewCheckmarkInset: CGFloat {
        return 12.5
    }
    
    // MARK: - Initialization
    
    public init(mediaType: ImagePickerMediaType, selectedAssets:[PHAsset] = []) {
        self.mediaType = mediaType
        self.selectedAssets = selectedAssets
        
        super.init(nibName: nil, bundle: nil)
        initialize()
        
        self.sheetController.numberOfSelectedAssets = selectedAssets.count
    }

    public required init?(coder aDecoder: NSCoder) {
        self.mediaType = .imageAndVideo
        super.init(coder: aDecoder)
        initialize()
    }
    
    fileprivate func initialize() {
        modalPresentationStyle = .custom
        transitioningDelegate = self
        
        NotificationCenter.default.addObserver(sheetController, selector: #selector(SheetController.handleCancelAction), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(sheetController, name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    
    // MARK: - View Lifecycle
    
    override open func loadView() {
        super.loadView()
        
        view.addSubview(backgroundView)
        view.addSubview(sheetCollectionView)
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        guard mediaType != .none else { return }
        
        preferredContentSize = CGSize(width: 400, height: view.frame.height)
        
        if PHPhotoLibrary.authorizationStatus() == .authorized {
            prepareAssets()
        }
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if PHPhotoLibrary.authorizationStatus() == .notDetermined {
            PHPhotoLibrary.requestAuthorization() { status in
                if status == .authorized {
                    DispatchQueue.main.async {
                        self.prepareAssets()
                        self.previewCollectionView.reloadData()
                        self.sheetCollectionView.reloadData()
                        self.view.setNeedsLayout()
                        
                        // Explicitely disable animations so it wouldn't animate either
                        // if it was in a popover
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.view.layoutIfNeeded()
                        CATransaction.commit()
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    /// Adds an new action.
    /// If the passed action is of type Cancel, any pre-existing Cancel actions will be removed.
    /// Always arranges the actions so that the Cancel action appears at the bottom.
    open func addAction(_ action: ImagePickerAction) {
        sheetController.addAction(action)
        view.setNeedsLayout()
    }
    
    // MARK: - Images
    
    fileprivate func sizeForAsset(_ asset: PHAsset, scale: CGFloat = 1) -> CGSize {
        let proportion = CGFloat(asset.pixelWidth)/CGFloat(asset.pixelHeight)
    
        let imageHeight = maximumPreviewHeight - 2 * previewInset
        let imageWidth = floor(proportion * imageHeight)
        
        return CGSize(width: imageWidth * scale, height: imageHeight * scale)
    }
    
    fileprivate func prepareAssets() {
        if mediaType == .none {
            return
        }
        
        fetchAssets()
        reloadMaximumPreviewHeight()
        reloadCurrentPreviewHeight(invalidateLayout: false)
        
        // Filter out the assets that are too thin. This can't be done before because
        // we don't know how tall the images should be
        let minImageWidth = 2 * previewCheckmarkInset + (PreviewSupplementaryView.checkmarkImage?.size.width ?? 0)
        assets = assets.filter { asset in
            let size = sizeForAsset(asset)
            return size.width >= minImageWidth
        }
    }
    
    fileprivate func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        switch mediaType {
        case .image:
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        case .video:
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        case .imageAndVideo:
            options.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .none:
            return
        }
        
        let fetchLimit = 50
        options.fetchLimit = fetchLimit
        
        let result = PHAsset.fetchAssets(with: options)
        let amount = min(result.count, fetchLimit)
        
        self.assets = result.objects(at: NSIndexSet(indexesIn: NSRange(location: 0, length: amount)) as IndexSet) as? [PHAsset] ?? []
        sheetController.reloadActionItems()
        
        for asset in selectedAssets {
            if let index = assets.index(of: asset) {
                previewCollectionView.selectItem(at: IndexPath(item: 0, section: index), animated: false, scrollPosition: [])
            }
        }
    }
    
    fileprivate func requestImageForAsset(asset: PHAsset, completion: @escaping (_ image: UIImage?, _ requestId: PHImageRequestID?) -> ()) -> PHImageRequestID {
        if let manager = self.imageManager  {
            let targetSize = sizeForAsset(asset, scale: UIScreen.main.scale)
            requestOptions.isSynchronous = false
            
            // Workaround because PHImageManager.requestImageForAsset doesn't work for burst images
            if asset.representsBurst {
                return manager.requestImageData(for: asset, options: requestOptions) { data, _, _, dict in
                    let image = data.flatMap { UIImage(data: $0) }
                    let requestId = dict?[PHImageResultRequestIDKey] as? NSNumber
                    completion(image, requestId as PHImageRequestID?)
                }
            }
            else {
                return manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, dict in
                    let requestId = dict?[PHImageResultRequestIDKey] as? NSNumber
                    completion(image, requestId as PHImageRequestID?)
                }
            }
        }
        
        return 0
    }
    
    fileprivate func prefetchImagesForAsset(_ asset: PHAsset) {
        let targetSize = sizeForAsset(asset, scale: UIScreen.main.scale)
        imageManager?.startCachingImages(for: [asset], targetSize: targetSize, contentMode: .aspectFill, options: requestOptions)
    }
    
    // MARK: - Layout
    
    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        if popoverPresentationController == nil {
            // Offset necessary for expanded status bar
            // Bug in UIKit which doesn't reset the view's frame correctly
            
            let offset = UIApplication.shared.statusBarFrame.height
            var backgroundViewFrame = UIScreen.main.bounds
            backgroundViewFrame.origin.y = -offset
            backgroundViewFrame.size.height += offset
            backgroundView.frame = backgroundViewFrame
        }
        else {
            backgroundView.frame = view.bounds
        }
        
        reloadMaximumPreviewHeight()
        reloadCurrentPreviewHeight(invalidateLayout: true)
        
        let sheetHeight = sheetController.preferredSheetHeight
        let sheetSize = CGSize(width: view.bounds.width, height: sheetHeight)
        
        // This particular order is necessary so that the sheet is layed out
        // correctly with and without an enclosing popover
        preferredContentSize = sheetSize
        sheetCollectionView.frame = CGRect(origin: CGPoint(x: view.bounds.minX, y: view.bounds.maxY - view.frame.origin.y - sheetHeight), size: sheetSize)
    }
    
    fileprivate func reloadCurrentPreviewHeight(invalidateLayout invalidate: Bool) {
        if assets.count <= 0 {
            sheetController.setPreviewHeight(0, invalidateLayout: invalidate)
        }
        else if assets.count > 0 && enlargedPreviews {
            sheetController.setPreviewHeight(maximumPreviewHeight, invalidateLayout: invalidate)
        }
        else {
            sheetController.setPreviewHeight(minimumPreviewHeight, invalidateLayout: invalidate)
        }
    }
    
    fileprivate func reloadMaximumPreviewHeight() {
        let maxHeight: CGFloat = 400
        let maxImageWidth = view.bounds.width - 2 * sheetInset - 2 * previewInset

        let assetRatios = assets.map { (asset: PHAsset) -> CGSize in
                CGSize(width: max(asset.pixelHeight, asset.pixelWidth), height: min(asset.pixelHeight, asset.pixelWidth))
            }.map { (size: CGSize) -> CGFloat in
                size.height / size.width
            }

        let assetHeights = assetRatios.map { (ratio: CGFloat) -> CGFloat in ratio * maxImageWidth }
                                      .filter { (height: CGFloat) -> Bool in height < maxImageWidth && height < maxHeight } // Make sure the preview isn't too high eg for squares
                                      .sorted(by: >)
        let assetHeight: CGFloat
        if let first = assetHeights.first {
            assetHeight = first
        }
        else {
            assetHeight = 0
        }

        // Just a sanity check, to make sure this doesn't exceed 400 points
        let scaledHeight: CGFloat = min(assetHeight, maxHeight)
        maximumPreviewHeight = scaledHeight + 2 * previewInset
    }
    
    // MARK: -
    
    func enlargePreviewsByCenteringToIndexPath(_ indexPath: IndexPath?, completion: (() -> ())?) {
        enlargedPreviews = true
        previewCollectionView.imagePreviewLayout.invalidationCenteredIndexPath = indexPath
        reloadCurrentPreviewHeight(invalidateLayout: false)
        
        view.setNeedsLayout()
        
        self.delegate?.controllerWillEnlargePreview?(self)
        
        UIView.animate(withDuration: 0.2, animations: {
            self.view.layoutIfNeeded()
            self.sheetCollectionView.collectionViewLayout.invalidateLayout()
        }, completion: { _ in
            self.delegate?.controllerDidEnlargePreview?(self)
            
            completion?()
        })
    }
}

// MARK: - UICollectionViewDataSource

extension ImagePickerSheetController: UICollectionViewDataSource {
    
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        return self.mediaType == .none ? 0 : assets.count
    }
    
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 1
    }
    
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NSStringFromClass(PreviewCollectionViewCell.self), for: indexPath) as! PreviewCollectionViewCell
        
        if let imageManager = self.imageManager {
            let asset = assets[indexPath.section]
            if let id = cell.requestId {
                imageManager.cancelImageRequest(id)
                cell.requestId = nil
            }
            cell.videoIndicatorView.isHidden = asset.mediaType != .video
            
            cell.requestId = requestImageForAsset(asset: asset) { image, requestId in
                if requestId == cell.requestId || cell.requestId == nil {
                    cell.imageView.image = image
                }
            }
            
            cell.isSelected = selectedAssets.contains(asset)
        }
        
        return cell
    }
    
    public func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath:
        IndexPath) -> UICollectionReusableView {
        let asset = assets[indexPath.section]
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionElementKindSectionHeader, withReuseIdentifier: NSStringFromClass(PreviewSupplementaryView.self), for: indexPath) as! PreviewSupplementaryView
        view.isUserInteractionEnabled = false
        view.buttonInset = UIEdgeInsetsMake(0.0, previewCheckmarkInset, previewCheckmarkInset, 0.0)
        
        supplementaryViews[indexPath.section] = view
        view.selected = selectedAssets.contains(asset)
        view.tintColor = tintColor
        return view
    }
}

// MARK: - UICollectionViewDelegate

extension ImagePickerSheetController: UICollectionViewDelegate {
    
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let maximumSelection = maximumSelection {
            if selectedAssets.count >= maximumSelection,
                let previousAsset = selectedAssets.first,
                let previousItemIndex = assets.index(of: previousAsset) {
                
                let previousItemIndexPath = IndexPath(item: 0, section: previousItemIndex)
                supplementaryViews[previousItemIndex]?.selected = false
                selectedAssets.remove(previousAsset)
                collectionView.deselectItem(at: previousItemIndexPath, animated: true)
            }
        }
        
        let selectedAsset = assets[indexPath.section]
        delegate?.controller?(self, willSelectAsset: selectedAsset)
        
        let asset = assets[indexPath.section]
        // Just to make sure the image is only selected once
        if !selectedAssets.contains(asset) {
            selectedAssets.append(asset)
        }
        
        if !enlargedPreviews {
            enlargePreviewsByCenteringToIndexPath(indexPath) {
                self.sheetController.reloadActionItems()
                self.previewCollectionView.imagePreviewLayout.showsSupplementaryViews = true
            }
        }
        else {
            // scrollToItemAtIndexPath doesn't work reliably
            if let cell = collectionView.cellForItem(at: indexPath) {
                var contentOffset = CGPoint(x: cell.frame.midX - collectionView.frame.width / 2.0, y: 0.0)
                contentOffset.x = max(contentOffset.x, -collectionView.contentInset.left)
                contentOffset.x = min(contentOffset.x, collectionView.contentSize.width - collectionView.frame.width + collectionView.contentInset.right)
                
                collectionView.setContentOffset(contentOffset, animated: true)
            }
            
            sheetController.reloadActionItems()
        }
        
        supplementaryViews[indexPath.section]?.selected = true
        
        delegate?.controller?(self, didSelectAsset: selectedAsset)
    }
    
    public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        
        if let asset = assets.object(at: indexPath.section) {
            delegate?.controller?(self, willDeselectAsset: asset)
            
            selectedAssets.remove(asset)
            sheetController.reloadActionItems()
            
            delegate?.controller?(self, didDeselectAsset: asset)
        }
        
        supplementaryViews[indexPath.section]?.selected = false
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension ImagePickerSheetController: UICollectionViewDelegateFlowLayout {
    
    public func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let asset = assets[indexPath.section]
        let size = sizeForAsset(asset)
        
        // Scale down to the current preview height, sizeForAsset returns the original size
        let currentImagePreviewHeight = sheetController.previewHeight - 2 * previewInset
        let scale = currentImagePreviewHeight / size.height
        
        return CGSize(width: size.width * scale, height: currentImagePreviewHeight)
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        let checkmarkWidth = PreviewSupplementaryView.checkmarkImage?.size.width ?? 0
        return CGSize(width: checkmarkWidth + 2 * previewCheckmarkInset, height: sheetController.previewHeight - 2 * previewInset)
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension ImagePickerSheetController: UIViewControllerTransitioningDelegate {
    
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AnimationController(imagePickerSheetController: self, presenting: true)
    }
    
    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AnimationController(imagePickerSheetController: self, presenting: false)
    }
}

private extension Array where Element : Equatable {
    func object(at: Int) -> Element? {
        
        if self.count > at {
            return self[at]
        }
        return nil
    }
    
    mutating func remove(_ element: Element) {
        
        if let index = self.index(of: element) {
            self.remove(at: index)
        }
    }
}
