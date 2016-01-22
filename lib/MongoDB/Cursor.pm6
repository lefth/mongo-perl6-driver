use v6;
use BSON::Document;
use MongoDB::Wire;

#-------------------------------------------------------------------------------
#
package MongoDB {

  #-------------------------------------------------------------------------------
  #
  class Cursor {

    has $.collection;
    has $.full-collection-name;

    # Cursor id ia an int64 (8 byte buffer). When set to 8 0 bytes, there are
    # no documents on the server or the cursor is killed.
    #
    has Buf $.id;

    # Batch of documents in last response
    #
    has @.documents;
    
    has BSON::Document $!read-concern;

    #-----------------------------------------------------------------------------
    # Support for the newer BSON::Document
    #
    multi submethod BUILD (
      :$collection!,
      BSON::Document:D :$server-reply,
      BSON::Document :$read-concern = BSON::Document.new
    ) {

      $!collection = $collection;
      $!full-collection-name = $!collection.full-collection-name;

      # Get cursor id from reply. Will be 8 * 0 bytes when there are no more
      # batches left on the server to retrieve. Documents may be present in
      # this reply.
      #
      $!id = $server-reply<cursor-id>;

      # Get documents from the reply.
      #
      @!documents = $server-reply<documents>.list;
      
      $!read-concern = $read-concern;
    }

    # This can be set with data received from a command e.g. listDocuments
    #
    multi submethod BUILD (
      BSON::Document:D :$cursor-doc!,
      BSON::Document :$read-concern = BSON::Document.new
    ) {

#TODO Check provided structure for the fields.

      $!collection = $cursor-doc<ns>;
      $!full-collection-name = $cursor-doc<ns>;

      # Get cursor id from reply. Will be 8 * 0 bytes when there are no more
      # batches left on the server to retrieve. Documents may be present in
      # this reply.
      #
      my BSON::Document $d .= new; 
      $d does MongoDB::Header;

      $!id = $d.encode-cursor-id($cursor-doc<id>);

      # Get documents from the reply.
      #
      @!documents = @($cursor-doc<firstBatch>);

      $!read-concern = $read-concern;
    }

    #-----------------------------------------------------------------------------
    method fetch ( --> BSON::Document ) {

      # If there are no more documents in last response batch but there is
      # still a next batch(sum of id bytes not 0) to fetch from database.
      #
      if not @!documents and ([+] $!id.list) {

        # Request next batch of documents
        #
        my BSON::Document $server-reply =
          MongoDB::Wire.instance.get-more( self, :$!read-concern);

        # Get cursor id, It may change to "0" if there are no more
        # documents to fetch.
        #
        $!id = $server-reply<cursor-id>;

        # Get documents
        #
        @!documents = $server-reply<documents>.list;
      }

      # Return a document when there is one. If none left, return Nil
      #
      return +@!documents ?? @!documents.shift !! Nil;
    }

    #-----------------------------------------------------------------------------
    method kill ( --> Nil ) {

      # Invalidate cursor on database
      MongoDB::Wire.instance.kill-cursors( (self,), :$!read-concern);

      # Invalidate cursor id with 8 0x00 bytes
      #
      $!id = Buf.new(0x00 xx 8);

      return;
    }
  }
}

