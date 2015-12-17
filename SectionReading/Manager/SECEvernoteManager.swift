//
//  SECEvernoteManager.swift
//  SectionReading
//
//  Created by guangbo on 15/12/15.
//  Copyright © 2015年 pengguangbo. All rights reserved.
//

import UIKit
import evernote_cloud_sdk_ios

/**
 印象笔记同步错误
 */
enum EvernoteSyncError: ErrorType {
    case NoError
    case EvernoteNotAuthenticated
    case FailToListNotebooks
    case FailToCreateNotebook
}

enum EvernoteSyncType {
    case UP
    case DOWN
}

let ApplicationNotebookName = "SectionReading"
let kApplicationNotebookGuid = "kApplicationNotebookGuid"
let kEvernoteLastUpdateCount = "kEvernoteLastUpdateCount"

class SECEvernoteManager: NSObject {

    private var noteSession = ENSession.sharedSession()
    
    private lazy var noteSycnOperationQueue: NSOperationQueue = {
        let queue = NSOperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    /**
     印象笔记是否授权
     
     - returns:
     */
    func isAuthenticated() -> Bool {

        return noteSession.isAuthenticated
    }
    
    /**
     印象笔记授权
     
     - parameter viewController:
     - parameter completion:
     */
    func authenticate(withViewController viewController: UIViewController, completion:((success: Bool) -> Void)?) {
        
        noteSession.authenticateWithViewController(viewController, preferRegistration: false) { [weak self] (error) -> Void in
            if let strongSelf = self {
                if error == nil {
                    // 设置笔记本
                    strongSelf.setupApplicationNotebook(withCompletion: { (result) -> Void in
                        
                        completion?(success: result == .NoError)
                    })
                } else {
                    completion?(success: false)
                }
            }
        }
    }
    
    /**
     印象笔记解除授权
     */
    func unauthenticate() {
        
        noteSession.unauthenticate()
    }
    
    /**
     设置好本应用的笔记本
     */
    private func setupApplicationNotebook(withCompletion completion: ((result: EvernoteSyncError) -> Void)?) {
        
        let notebookGuid = NSUserDefaults.standardUserDefaults().objectForKey(kApplicationNotebookGuid) as? String
        if notebookGuid != nil {
            noteSession.primaryNoteStore().getNotebookWithGuid(notebookGuid!, success: { [weak self] (notebook) -> Void in
                
                if let strongSelf = self {
                    if notebook.name != ApplicationNotebookName {
                        strongSelf.createApplicationNotebook(withCompletion: completion)
                    }
                }
            }, failure: { [weak self] (error) -> Void in
                
                if let strongSelf = self {
                    strongSelf.createApplicationNotebook(withCompletion: completion)
                }
            })
        } else {
            noteSession.primaryNoteStore().listNotebooksWithSuccess({ [weak self] (books) -> Void in
                
                if let strongSelf = self {
                    var targetNotebook: EDAMNotebook?
                    for notebook in books {
                        if notebook.name == ApplicationNotebookName {
                            targetNotebook = notebook as? EDAMNotebook
                            break
                        }
                    }
                    if targetNotebook != nil {
                        NSUserDefaults.standardUserDefaults().setObject(targetNotebook!.guid, forKey: kApplicationNotebookGuid)
                        completion?(result: EvernoteSyncError.NoError)
                        return
                    }
                    
                    strongSelf.createApplicationNotebook(withCompletion: completion)
                }
            }, failure: { (error) -> Void in
                print("Fail to listNotebooks, error: \(error.localizedDescription)")
                completion?(result: EvernoteSyncError.FailToListNotebooks)
            })
        }
    }
    
    private func createApplicationNotebook(withCompletion completion: ((result: EvernoteSyncError) -> Void)?) {
    
        let notebook = EDAMNotebook()
        notebook.name = ApplicationNotebookName
        notebook.defaultNotebook = NSNumber(bool: false)
        noteSession.primaryNoteStore().createNotebook(notebook, success: { (notebook) -> Void in
            
            print("Success to createNotebook, guid: \(notebook.guid), name: \(notebook.name)")
            
            NSUserDefaults.standardUserDefaults().setObject(notebook.guid, forKey: kApplicationNotebookGuid)
            completion?(result: EvernoteSyncError.NoError)
            
            }) { (error) -> Void in
                print("Fail to createNotebook, error: \(error.localizedDescription)")
                completion?(result: EvernoteSyncError.FailToCreateNotebook)
        }
    }
    
    /**
     与印象笔记同步笔记
     
     - parameter type:       同步类型
     - parameter completion: 同步成功数量
     */
    func sync(type: EvernoteSyncType, completion: ((successNumber: Int) -> Void)?) {
        
        if isAuthenticated() == false {
            completion?(successNumber: 0)
            return
        }
        
        switch type {
        case .UP:
            syncUp(withCompletion: completion)
        case .DOWN:
            syncDown(withCompletion: completion)
        }
    }
    
    private func syncUp(withCompletion completion: ((successNumber: Int) -> Void)?) {
        
        self.noteSycnOperationQueue.addOperationWithBlock { () -> Void in
            
            let queryOption = ReadingQueryOption()
            queryOption.syncStatus = [.NeedSyncUpload, .NeedSyncDelete]
            TReading.filterByOption(queryOption) { [weak self] (results) -> Void in
                
                let strongSelf = self
                if strongSelf == nil {
                    return
                }
                if results == nil {
                    return
                }
                
                var successNumber = 0
                var dispatchGroup = dispatch_group_create()
                
                for reading in results! {
                    
                    let syncStatus = reading.fSyncStatus
                    if syncStatus == nil {
                        continue
                    }
                    
                    if syncStatus!.integerValue == ReadingSyncStatus.NeedSyncUpload.rawValue {
                        
                        if reading.fEvernoteGuid == nil {
                            // create
                            dispatch_group_enter(dispatchGroup)
                            strongSelf?.createNote(withContent: reading, completion: { (success) -> Void in
                                if success {
                                    ++successNumber
                                }
                                dispatch_group_leave(dispatchGroup)
                            })
                            dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
                        } else {
                            // update
                            dispatch_group_enter(dispatchGroup)
                            strongSelf?.updateNote(withGuid: reading.fEvernoteGuid!, newContent: reading, completion: { (success) -> Void in
                                if success {
                                    ++successNumber
                                }
                                dispatch_group_leave(dispatchGroup)
                            })
                            dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
                        }
                        
                    } else if syncStatus!.integerValue == ReadingSyncStatus.NeedSyncDelete.rawValue {
                        
                        if reading.fEvernoteGuid == nil {
                            continue
                        }
                        
                        // delete
                        dispatch_group_enter(dispatchGroup)
                        strongSelf?.deleteNote(reading.fEvernoteGuid!, completion: { (success) -> Void in
                            if success {
                                ++successNumber
                            }
                            dispatch_group_leave(dispatchGroup)
                        })
                        dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
                    }
                }
                
                dispatchGroup = nil
                completion?(successNumber: successNumber)
            }
        }
    }
    
    private func syncDown(withCompletion completion: ((successNumber: Int) -> Void)?) {
        
        let appNotebookGuid = NSUserDefaults.standardUserDefaults().objectForKey(kApplicationNotebookGuid) as? String
        if appNotebookGuid == nil {
            completion?(successNumber: 0)
            return
        }
        
        self.noteSycnOperationQueue.addOperationWithBlock { [weak self] () -> Void in
            
            var strongSelf = self
            if strongSelf == nil {
                return
            }
            
            let dispatchGroup = dispatch_group_create()
            
            // 考虑是否需要向下同步
            
            let latestUpdateCount = NSUserDefaults.standardUserDefaults().integerForKey(kEvernoteLastUpdateCount)
            var currentUpdateCount = 0
            
            dispatch_group_enter(dispatchGroup)
            strongSelf!.noteSession.primaryNoteStore().getSyncStateWithSuccess({ (syncState) -> Void in
                currentUpdateCount = syncState.updateCount.integerValue
                dispatch_group_leave(dispatchGroup)
                
                }, failure: { (error) -> Void in
                    print("Fail to getSyncState, error: \(error.localizedDescription)")
                    dispatch_group_leave(dispatchGroup)
            })
            dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
            
            if currentUpdateCount <= latestUpdateCount {
                completion?(successNumber: 0)
                return
            }
            
            strongSelf = self
            if strongSelf == nil {
                return
            }
            
            // 获取笔记数量
            
            var noteCount: NSNumber?
            let filter = EDAMNoteFilter()
            filter.notebookGuid = appNotebookGuid
            
            dispatch_group_enter(dispatchGroup)
            strongSelf!.noteSession.primaryNoteStore().findNoteCountsWithFilter(filter, withTrash: false, success: { (noteCollectionCounts) -> Void in
                noteCount = noteCollectionCounts.notebookCounts.values.first as? NSNumber
                dispatch_group_leave(dispatchGroup)
                
                }, failure: { (error) -> Void in
                    print("Fail to findNoteCounts, error: \(error.localizedDescription)")
                    dispatch_group_leave(dispatchGroup)
            })
            dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
            
            if noteCount == nil || noteCount!.integerValue == 0 {
                completion?(successNumber: 0)
                return
            }
            
            strongSelf = self
            if strongSelf == nil {
                return
            }
            
            // 开始向下同步
            
            var noteMetas: [EDAMNoteMetadata]?
            let resultSpec = EDAMNotesMetadataResultSpec()
            resultSpec.includeUpdated = true
            
            dispatch_group_enter(dispatchGroup)
            strongSelf!.noteSession.primaryNoteStore().findNotesMetadataWithFilter(filter, maxResults: noteCount!.unsignedIntegerValue, resultSpec: resultSpec, success: { (results) -> Void in
                
                noteMetas = results as? [EDAMNoteMetadata]
                dispatch_group_leave(dispatchGroup)
                
                }, failure: { (error) -> Void in
                    print("Fail to findNotesMetadata, error: \(error.localizedDescription)")
                    dispatch_group_leave(dispatchGroup)
            })
            dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
            
            if noteMetas == nil || noteMetas!.count == 0 {
                completion?(successNumber: 0)
                return
            }
            
            strongSelf = self
            if strongSelf == nil {
                return
            }
            
            var syncDownNumber = 0
            
            for noteMeta in noteMetas! {
                
                // 获取当前笔记的全部信息
                
                var note: EDAMNote?
                
                dispatch_group_enter(dispatchGroup)
                strongSelf!.noteSession.primaryNoteStore().getNoteWithGuid(noteMeta.guid, withContent: true, withResourcesData: false, withResourcesRecognition: false, withResourcesAlternateData: false, success: { (result) -> Void in
                    note = result
                    dispatch_group_leave(dispatchGroup)

                    }, failure: { (error) -> Void in
                        print("Fail to findNotesMetadata, error: \(error.localizedDescription)")
                        dispatch_group_leave(dispatchGroup)
                })
                dispatch_group_wait(dispatchGroup, DISPATCH_TIME_FOREVER)
                
                strongSelf = self
                if strongSelf == nil {
                    return
                }
                
                if note == nil {
                    continue
                }
                
                let queryOption = ReadingQueryOption()
                queryOption.evernoteGuid = noteMeta.guid
                let existCount = TReading.count(withOption: queryOption)
                
                if existCount != nil && existCount! > 0  {
                    // 本地已有改信息，更新它
                    TReading.update(withFilterOption: queryOption, updateBlock: { (readingtoUpdate) -> Void in
                        readingtoUpdate.fillFields(fromEverNote: note!)
                    })
                } else {
                    // 本地没有该信息，下载它
                    TReading.create(withConstructBlock: { (newReading) -> Void in
                        newReading.fillFields(fromEverNote: note!)
                        newReading.fLocalId = NSUUID().UUIDString
                    })
                }
                
                ++syncDownNumber
            }
            
            completion?(successNumber: syncDownNumber)
        }
    }
    
    private func createNote(withContent content: TReading, completion: ((success: Bool) -> Void)?) {
        
        let appNotebookGuid = NSUserDefaults.standardUserDefaults().objectForKey(kApplicationNotebookGuid) as? String
        if appNotebookGuid == nil {
            completion?(success: false)
            return
        }
        
        let note = EDAMNote()
        TReading.fillFieldsFor(note, withReading: content)
        
        note.notebookGuid = appNotebookGuid!
        note.title = ""
        
        noteSession.primaryNoteStore().createNote(note, success: { (createdNote) -> Void in
            
            // 更新本地数据
            let filterOption = ReadingQueryOption()
            filterOption.localId = content.fLocalId!
            
            TReading.update(withFilterOption: filterOption, updateBlock: { (readingtoUpdate) -> Void in
                
                readingtoUpdate.fillFields(fromEverNote: createdNote)
                readingtoUpdate.fSyncStatus = NSNumber(integer: ReadingSyncStatus.Normal.rawValue)
            })
            
            completion?(success: true)
            
            }, failure: { (error) -> Void in
                print("Fail to createNote, error: \(error.localizedDescription)")
                completion?(success: false)
        })
    }
    
    private func updateNote(withGuid guid: String, newContent: TReading, completion: ((success: Bool) -> Void)?) {
        
        let appNotebookGuid = NSUserDefaults.standardUserDefaults().objectForKey(kApplicationNotebookGuid) as? String
        if appNotebookGuid == nil {
            completion?(success: false)
            return
        }
        
        let note = EDAMNote()
        TReading.fillFieldsFor(note, withReading: newContent)
        
        note.guid = guid
        note.title = ""
        note.notebookGuid = appNotebookGuid!
        
        noteSession.primaryNoteStore().updateNote(note, success: { (updatedNote) -> Void in
            
            if newContent.fLocalId != nil {
                // 更新本地数据
                let filterOption = ReadingQueryOption()
                filterOption.localId = newContent.fLocalId!
                
                TReading.update(withFilterOption: filterOption, updateBlock: { (readingtoUpdate) -> Void in
                    
                    readingtoUpdate.fillFields(fromEverNote: updatedNote)
                    readingtoUpdate.fSyncStatus = NSNumber(integer: ReadingSyncStatus.Normal.rawValue)
                })
            }
            
            completion?(success: true)
            
            }) { (error) -> Void in
                print("Fail to createNote, error: \(error.localizedDescription)")
                completion?(success: false)
        }
    }
    
    private func deleteNote(withGuid: String, completion: ((success: Bool) -> Void)?) {
        
    }
}