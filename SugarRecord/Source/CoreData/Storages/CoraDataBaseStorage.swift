//
//  CoraDataBaseStorage.swift
//  iOSCoreData
//
//  Created by Gleb Oleinik on 4/11/18.
//  Copyright © 2018 in.caramba.SugarRecord. All rights reserved.
//

import Foundation
import CoreData

public class CoreDataBaseStorage {
    
    // MARK: - Attributes
    
    internal var store: CoreDataStore?
    internal var objectModel: NSManagedObjectModel! = nil
    internal var persistentStore: NSPersistentStore! = nil
    internal var persistentStoreCoordinator: NSPersistentStoreCoordinator! = nil
    internal var rootSavingContext: NSManagedObjectContext! = nil
    
    // MARK: - Common Public
    
    #if os(iOS) || os(tvOS) || os(watchOS)
    public func observable<T: NSManagedObject>(request: FetchRequest<T>) -> RequestObservable<T> {
        return CoreDataObservable(request: request, context: self.mainContext as! NSManagedObjectContext)
    }
    #endif
    
    public func operation<T>(_ operation: @escaping (_ context: Context, _ save: @escaping () -> Void) throws -> T) throws -> T {
        let context: NSManagedObjectContext = self.saveContext as! NSManagedObjectContext
        var _error: Error!
        
        var returnedObject: T!
        context.performAndWait {
            do {
                returnedObject = try operation(context, { () -> Void in
                    do {
                        try context.save()
                    }
                    catch {
                        _error = error
                    }
                    self.rootSavingContext.performAndWait({
                        if self.rootSavingContext.hasChanges {
                            do {
                                try self.rootSavingContext.save()
                            }
                            catch {
                                _error = error
                            }
                        }
                    })
                })
            } catch {
                _error = error
            }
        }
        if let error = _error {
            throw error
        }
        
        return returnedObject
    }
    
    public func backgroundOperation(_ operation: @escaping (_ context: Context, _ save: @escaping () -> Void) -> (), completion: @escaping (Error?) -> ()) {
        let context: NSManagedObjectContext = self.saveContext as! NSManagedObjectContext
        var _error: Error!
        context.perform {
            operation(context, { () -> Void in
                do {
                    try context.save()
                }
                catch {
                    _error = error
                }
                self.rootSavingContext.perform {
                    if self.rootSavingContext.hasChanges {
                        do {
                            try self.rootSavingContext.save()
                        }
                        catch {
                            _error = error
                        }
                    }
                    completion(_error)
                }
            })
        }
    }
    
    // MARK: - Storage
    public var type: StorageType = .coreData
    public var mainContext: Context!

    internal var _saveContext: Context!
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
        get {
            let context =  cdContext(withParent: .context(self.rootSavingContext), concurrencyType: .privateQueueConcurrencyType, inMemory: true)
            return context
        }
    }
    
    
    
    // MARK: - Init
    
    internal init(model: CoreDataObjectModel, versionController: VersionController) {
        self.objectModel = model.model()!
        self.rootSavingContext = cdContext(withParent: .coordinator(self.persistentStoreCoordinator), concurrencyType: .privateQueueConcurrencyType, inMemory: false)
        self.mainContext = cdContext(withParent: .context(self.rootSavingContext), concurrencyType: .mainQueueConcurrencyType, inMemory: false)
        
        #if DEBUG
        versionController.check()
        #endif
    }
}
