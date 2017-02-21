import Foundation
import CoreData

#if os(iOS) || os(tvOS) || os(watchOS)
public class CoreDataDefaultStorage: Storage {
    
    // MARK: - Attributes
    
    internal let store: CoreDataStore
    internal var objectModel: NSManagedObjectModel! = nil
    internal var persistentStore: NSPersistentStore! = nil
    internal var persistentStoreCoordinator: NSPersistentStoreCoordinator! = nil
    internal var rootSavingContext: NSManagedObjectContext! = nil

    
    // MARK: - Storage conformance
    
    public var description: String {
        get {
            return "CoreDataDefaultStorage"
        }
    }
    
    public var type: StorageType = .coreData
    public var mainContext: Context!
    private var _saveContext: Context!
    public var saveContext: Context! {
        if let context = self._saveContext {
            return context
        }
        let _context = cdContext(withParent: .context(self.rootSavingContext), concurrencyType: .privateQueueConcurrencyType, inMemory: false)
        _context.observe(inMainThread: true) { [weak self] (notification) -> Void in
            (self?.mainContext as? NSManagedObjectContext)?.mergeChanges(fromContextDidSave: notification as Notification)
        }
        self._saveContext = _context
        return _context
    }
    public var memoryContext: Context! {
        let _context =  cdContext(withParent: .context(self.rootSavingContext), concurrencyType: .privateQueueConcurrencyType, inMemory: true)
        return _context
    }
    
    public func removeStore() throws {
        try FileManager.default.removeItem(at: store.path() as URL)
        _ = try? FileManager.default.removeItem(atPath: "\(store.path().absoluteString)-shm")
        _ = try? FileManager.default.removeItem(atPath: "\(store.path().absoluteString)-wal")

    }
    
    
    // MARK: - Init
    
    public convenience init(store: CoreDataStore, model: CoreDataObjectModel, migrate: Bool = true) throws {
        try self.init(store: store, model: model, migrate: migrate, versionController: VersionController())
    }
    
    internal init(store: CoreDataStore, model: CoreDataObjectModel, migrate: Bool = true, versionController: VersionController) throws {
        self.store   = store
        self.objectModel = model.model()!
        self.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: objectModel)
        self.persistentStore = try cdInitializeStore(store: store, storeCoordinator: persistentStoreCoordinator, migrate: migrate)
        self.rootSavingContext = cdContext(withParent: .coordinator(self.persistentStoreCoordinator), concurrencyType: .privateQueueConcurrencyType, inMemory: false)
        self.mainContext = cdContext(withParent: .context(self.rootSavingContext), concurrencyType: .mainQueueConcurrencyType, inMemory: false)
        #if DEBUG
        versionController.check()
        #endif
    }
}
#endif

// MARK: - Internal

internal func cdContext(withParent parent: CoreDataContextParent?, concurrencyType: NSManagedObjectContextConcurrencyType, inMemory: Bool) -> NSManagedObjectContext {
    var context: NSManagedObjectContext?
    if inMemory {
        context = NSManagedObjectMemoryContext(concurrencyType: concurrencyType)
    }
    else {
        context = NSManagedObjectContext(concurrencyType: concurrencyType)
    }
    if let parent = parent {
        switch parent {
        case .context(let parentContext):
            context!.parent = parentContext
        case .coordinator(let storeCoordinator):
            context!.persistentStoreCoordinator = storeCoordinator
        }
    }
    context!.observeToGetPermanentIDsBeforeSaving()
    return context!
}

internal func cdInitializeStore(store: CoreDataStore, storeCoordinator: NSPersistentStoreCoordinator, migrate: Bool) throws -> NSPersistentStore {
    try cdCreateStoreParentPathIfNeeded(store: store)
    let options = migrate ? CoreDataOptions.migration : CoreDataOptions.basic
    return try cdAddPersistentStore(store: store, storeCoordinator: storeCoordinator, options: options.dict())
}

internal func cdCreateStoreParentPathIfNeeded(store: CoreDataStore) throws {
    let databaseParentPath = store.path().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: databaseParentPath, withIntermediateDirectories: true, attributes: nil)
}

internal func cdAddPersistentStore(store: CoreDataStore, storeCoordinator: NSPersistentStoreCoordinator, options: [String: AnyObject]) throws -> NSPersistentStore {
    
    var addStore: ((_ store: CoreDataStore,  _ storeCoordinator: NSPersistentStoreCoordinator, _ options: [String: AnyObject], _ cleanAndRetryIfMigrationFails: Bool) throws -> NSPersistentStore)?
    addStore = { (store: CoreDataStore, coordinator: NSPersistentStoreCoordinator, options: [String: AnyObject], retry: Bool) throws -> NSPersistentStore in
        var persistentStore: NSPersistentStore?
        var error: NSError?
        coordinator.performAndWait({ () -> Void in
            do {
                persistentStore = try storeCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: store.path() as URL, options: options)
            }
            catch let _error as NSError {
                error = _error
            }
        })
        if let error = error {
            let isMigrationError = error.code == NSPersistentStoreIncompatibleVersionHashError || error.code == NSMigrationMissingSourceModelError
            if isMigrationError && retry {
                _ = try? cdCleanStoreFilesAfterFailedMigration(store: store)
                return try addStore!(store, coordinator, options, false)
            }
            else {
                throw error
            }
        }
        else if let persistentStore = persistentStore {
            return persistentStore
        }
        throw CoreDataError.persistenceStoreInitialization
    }
    return try addStore!(store, storeCoordinator, options, true)
}

internal func cdCleanStoreFilesAfterFailedMigration(store: CoreDataStore) throws {
    let rawUrl: String = store.path().absoluteString
    let shmSidecar: NSURL = NSURL(string: rawUrl.appending("-shm"))!
    let walSidecar: NSURL = NSURL(string: rawUrl.appending("-wal"))!
    try FileManager.default.removeItem(at: store.path() as URL)
    try FileManager.default.removeItem(at: shmSidecar as URL)
    try FileManager.default.removeItem(at: walSidecar as URL)
}
