/*****************************************************************************
 * VLCMediaList.m: VLC.framework VLCMediaList implementation
 *****************************************************************************
 * Copyright (C) 2007 Pierre d'Herbemont
 * Copyright (C) 2007 the VideoLAN team
 * $Id$
 *
 * Authors: Pierre d'Herbemont <pdherbemont # videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCMediaList.h"
#import "VLCLibrary.h"
#import "VLCEventManager.h"
#import "VLCLibVLCBridging.h"
#include <vlc/vlc.h>
#include <vlc/libvlc.h>

/* Notification Messages */
NSString *VLCMediaListItemAdded        = @"VLCMediaListItemAdded";
NSString *VLCMediaListItemDeleted    = @"VLCMediaListItemDeleted";

// TODO: Documentation
@interface VLCMediaList (Private)
/* Initializers */
- (void)initInternalMediaList;

/* Libvlc event bridges */
- (void)mediaListItemAdded:(NSDictionary *)args;
- (void)mediaListItemRemoved:(NSNumber *)index;
@end

/* libvlc event callback */
static void HandleMediaListItemAdded(const libvlc_event_t *event, void *user_data)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    id self = user_data;
    int index = event->u.media_list_item_added.index;
    [self didChange:NSKeyValueChangeInsertion valuesAtIndexes:[NSIndexSet indexSetWithIndex:index] forKey:@"Media"];
    [[VLCEventManager sharedManager] callOnMainThreadObject:self 
                                                 withMethod:@selector(mediaListItemAdded:) 
                                       withArgumentAsObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                                          [VLCMedia mediaWithLibVLCMediaDescriptor:event->u.media_list_item_added.item], @"media",
                                                          [NSNumber numberWithInt:event->u.media_list_item_added.index], @"index",
                                                          nil]];
    [pool release];
}
static void HandleMediaListWillAddItem(const libvlc_event_t *event, void *user_data)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    id self = user_data;
    int index = event->u.media_list_will_add_item.index;
    [self willChange:NSKeyValueChangeInsertion valuesAtIndexes:[NSIndexSet indexSetWithIndex:index] forKey:@"Media"];
    [pool release];
}


static void HandleMediaListItemDeleted( const libvlc_event_t * event, void * user_data)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    id self = user_data;
    int index = event->u.media_list_will_add_item.index;
    [self didChange:NSKeyValueChangeRemoval valuesAtIndexes:[NSIndexSet indexSetWithIndex:index] forKey:@"Media"];
    // Check to see if the last item deleted is this item we're trying delete now.
    // If no, then delete the item from the local list, otherwise, the item has already 
    // been deleted
    [[VLCEventManager sharedManager] callOnMainThreadObject:self 
                                                 withMethod:@selector(mediaListItemRemoved:) 
                                       withArgumentAsObject:[NSNumber numberWithInt:event->u.media_list_item_deleted.index]];
    [pool release];
}

static void HandleMediaListWillDeleteItem(const libvlc_event_t *event, void *user_data)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    id self = user_data;
    int index = event->u.media_list_will_add_item.index;
    [self willChange:NSKeyValueChangeRemoval valuesAtIndexes:[NSIndexSet indexSetWithIndex:index] forKey:@"Media"];
    [pool release];
}

@implementation VLCMediaList (KeyValueCodingCompliance)
/* For the @"Media" key */
- (int) countOfMedia
{
    return [self count];
}

- (id) objectInMediaAtIndex:(int)i
{
    return [self mediaAtIndex:i];
}
@end

@implementation VLCMediaList
- (id)init
{
    if (self = [super init])
    {
        // Create a new libvlc media list instance
        libvlc_exception_t p_e;
        libvlc_exception_init(&p_e);
        p_mlist = libvlc_media_list_new([VLCLibrary sharedInstance], &p_e);
        quit_on_exception(&p_e);
        
        // Initialize internals to defaults
        delegate = nil;
        [self initInternalMediaList];
    }
    return self;
}

- (void)release
{
    @synchronized(self)
    {
        if([self retainCount] <= 1)
        {
            /* We must make sure we won't receive new event after an upcoming dealloc
             * We also may receive a -retain in some event callback that may occcur
             * Before libvlc_event_detach. So this can't happen in dealloc */
            libvlc_event_manager_t * p_em = libvlc_media_list_event_manager(p_mlist, NULL);
            libvlc_event_detach(p_em, libvlc_MediaListItemDeleted, HandleMediaListItemDeleted, self, NULL);
            libvlc_event_detach(p_em, libvlc_MediaListWillDeleteItem, HandleMediaListWillDeleteItem, self, NULL);
            libvlc_event_detach(p_em, libvlc_MediaListItemAdded,   HandleMediaListItemAdded,   self, NULL);
            libvlc_event_detach(p_em, libvlc_MediaListWillAddItem, HandleMediaListWillAddItem, self, NULL);
        }
        [super release];
    }
}

- (void)dealloc
{
    // Release allocated memory
    libvlc_media_list_release(p_mlist);
    
    [super dealloc];
}

- (void)setDelegate:(id)value
{
    delegate = value;
}

- (id)delegate
{
    return delegate;
}

- (void)lock
{
    libvlc_media_list_lock( p_mlist );
}

- (void)unlock
{
    libvlc_media_list_unlock( p_mlist );
}

- (int)addMedia:(VLCMedia *)media
{
    int index = [self count];
    [self insertMedia:media atIndex:index];
    return index;
}

- (void)insertMedia:(VLCMedia *)media atIndex: (int)index
{
    [media retain];
    
    // Add it to the libvlc's medialist
    libvlc_exception_t p_e;
    libvlc_exception_init( &p_e );
    libvlc_media_list_insert_media_descriptor( p_mlist, [media libVLCMediaDescriptor], index, &p_e );
    quit_on_exception( &p_e );
}

- (void)removeMediaAtIndex:(int)index
{
    [[self mediaAtIndex:index] release];

    // Remove it from the libvlc's medialist
    libvlc_exception_t p_e;
    libvlc_exception_init( &p_e );
    libvlc_media_list_remove_index( p_mlist, index, &p_e );
    quit_on_exception( &p_e );
}

- (VLCMedia *)mediaAtIndex:(int)index
{
    libvlc_exception_t p_e;
    libvlc_exception_init( &p_e );
    libvlc_media_descriptor_t *p_md = libvlc_media_list_item_at_index( p_mlist, index, &p_e );
    quit_on_exception( &p_e );
    
    // Returns local object for media descriptor, searchs for user data first.  If not found it creates a 
    // new cocoa object representation of the media descriptor.
    return [VLCMedia mediaWithLibVLCMediaDescriptor:p_md];
}

- (int)count
{
    libvlc_exception_t p_e;
    libvlc_exception_init( &p_e );
    int result = libvlc_media_list_count( p_mlist, &p_e );
    quit_on_exception( &p_e );

    return result;
}

- (int)indexOfMedia:(VLCMedia *)media
{
    libvlc_exception_t p_e;
    libvlc_exception_init( &p_e );
    int result = libvlc_media_list_index_of_item( p_mlist, [media libVLCMediaDescriptor], &p_e );
    quit_on_exception( &p_e );
    
    return result;
}

/* Media list aspect */
- (VLCMediaListAspect *)hierarchicalAspect
{
    VLCMediaListAspect * hierarchicalAspect;
    libvlc_media_list_view_t * p_mlv = libvlc_media_list_hierarchical_view( p_mlist, NULL );
    hierarchicalAspect = [VLCMediaListAspect mediaListAspectWithLibVLCMediaListView: p_mlv];
    libvlc_media_list_view_release( p_mlv );
    return hierarchicalAspect;
}

- (VLCMediaListAspect *)flatAspect
{
    VLCMediaListAspect * flatAspect;
    libvlc_media_list_view_t * p_mlv = libvlc_media_list_flat_view( p_mlist, NULL );
    flatAspect = [VLCMediaListAspect mediaListAspectWithLibVLCMediaListView: p_mlv];
    libvlc_media_list_view_release( p_mlv );
    return flatAspect;
}

@end

@implementation VLCMediaList (LibVLCBridging)
+ (id)mediaListWithLibVLCMediaList:(void *)p_new_mlist;
{
    return [[[VLCMediaList alloc] initWithLibVLCMediaList:p_new_mlist] autorelease];
}

- (id)initWithLibVLCMediaList:(void *)p_new_mlist;
{
    if( self = [super init] )
    {
        p_mlist = p_new_mlist;
        libvlc_media_list_retain(p_mlist);
        [self initInternalMediaList];
    }
    return self;
}

- (void *)libVLCMediaList
{
    return p_mlist;
}
@end

@implementation VLCMediaList (Private)
- (void)initInternalMediaList
{
    // Add event callbacks
    [self lock];
    libvlc_exception_t p_e;
    libvlc_exception_init(&p_e);

    libvlc_event_manager_t *p_em = libvlc_media_list_event_manager( p_mlist, &p_e );
    libvlc_event_attach( p_em, libvlc_MediaListItemAdded,   HandleMediaListItemAdded,   self, &p_e );
    libvlc_event_attach( p_em, libvlc_MediaListWillAddItem, HandleMediaListWillAddItem, self, &p_e );
    libvlc_event_attach( p_em, libvlc_MediaListItemDeleted, HandleMediaListItemDeleted, self, &p_e );
    libvlc_event_attach( p_em, libvlc_MediaListWillDeleteItem, HandleMediaListWillDeleteItem, self, &p_e );
    [self unlock];
    
    quit_on_exception( &p_e );
}

- (void)mediaListItemAdded:(NSDictionary *)args
{    
    // Post the notification
    [[NSNotificationCenter defaultCenter] postNotificationName:VLCMediaListItemAdded
                                                        object:self
                                                      userInfo:args];
    
    // Let the delegate know that the item was added
    if (delegate && [delegate respondsToSelector:@selector(mediaList:mediaAdded:atIndex:)])
        [delegate mediaList:self mediaAdded:[args objectForKey:@"media"] atIndex:[[args objectForKey:@"index"] intValue]];
}

- (void)mediaListItemRemoved:(NSNumber *)index
{
    // Post the notification
    [[NSNotificationCenter defaultCenter] postNotificationName:VLCMediaListItemDeleted 
                                                        object:self
                                                      userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                          index, @"index",
                                                          nil]];
    
    // Let the delegate know that the item is being removed
    if (delegate && [delegate respondsToSelector:@selector(mediaList:mediaRemovedAtIndex:)])
        [delegate mediaList:self mediaRemovedAtIndex:[index intValue]];
}
@end

