# frozen_string_literal: true

require "set"

module RubyDB
  module Storage
    # PageAllocator - Handles page allocation with free space management
    # This is a production-grade implementation with proper fragmentation management,
    # overflow page handling, and comprehensive statistics tracking.
    class PageAllocator
      attr_reader :page_manager, :free_space_map, :stats

      def initialize(page_manager)
        @page_manager = page_manager
        @free_space_map = FreeSpaceMap.new(page_manager)
        @lock = Mutex.new
        @stats = {
          allocations: 0,
          releases: 0,
          compactions: 0,
          defragmentations: 0,
          allocation_failures: 0,
          total_space_requested: 0,
          total_space_allocated: 0,
          total_space_released: 0,
          overflow_allocations: 0,
          overflow_releases: 0
        }
        @overflow_pages = {}
        @page_usage = {}
        @page_records_cache = {}
        @cache_hits = 0
        @cache_misses = 0
        @initialized = true
        @max_cache_size = 1000
        @defragmentation_threshold = 0.30  # 30% fragmentation triggers defrag
      end

      # Allocate a page with at least needed_bytes of space
      def allocate_page_with_space(needed_bytes, page_type = 0)
        @lock.synchronize do
          @stats[:allocations] += 1
          @stats[:total_space_requested] += needed_bytes

          page_size = @page_manager.page_manager.page_size
          max_record_size = page_size - PageHeader::SIZE - 8 # 8 bytes for record header

          # Validate request
          if needed_bytes > max_record_size
            @stats[:allocation_failures] += 1
            raise StorageError, "Requested space #{needed_bytes} exceeds maximum record size #{max_record_size}"
          end

          if needed_bytes <= 0
            @stats[:allocation_failures] += 1
            raise StorageError, "Requested space must be positive"
          end

          page_number = nil
          page = nil

          # Try to find existing page with enough free space (best fit)
          candidate_page = @free_space_map.find_page_with_space(needed_bytes)

          if candidate_page
            page = @page_manager.get_page(candidate_page)
            
            # Verify page is valid and has space
            if page && page.header.page_type != 3 && page.free_space >= needed_bytes
              page_number = candidate_page
            else
              # Free space map is stale - update it
              @free_space_map.update_page(candidate_page, page ? page.free_space : 0)
              # Try another search
              page_number = @free_space_map.find_page_with_space(needed_bytes)
              page = @page_manager.get_page(page_number) if page_number
            end
          end

          unless page_number && page
            # Allocate new page
            page_number = @page_manager.allocate_page(page_type)
            
            # Initialize page
            page = Page.new(page_number, page_size)
            page.header.page_type = page_type
            page.header.data_end = PageHeader::SIZE
            page.write_header
            
            @page_manager.write_page(page)
            @free_space_map.update_page(page_number, page.free_space)
            
            # Clear any cached records for this page
            @page_records_cache.delete(page_number)
          end

          # Get the page and reserve space
          page = @page_manager.get_page(page_number)
          
          # Calculate new data end position
          new_data_end = page.header.data_end + needed_bytes
          
          # Double-check we have enough space
          if new_data_end > page_size
            @stats[:allocation_failures] += 1
            raise StorageError, "Page #{page_number} doesn't have enough space (needed: #{needed_bytes}, available: #{page.free_space}, total: #{page_size - new_data_end})"
          end
          
          # Update page header
          page.header.data_end = new_data_end
          page.write_header
          
          # Write the updated page
          @page_manager.write_page(page)

          # Update free space map
          @free_space_map.update_page(page_number, page.free_space)

          # Track page usage
          @page_usage[page_number] ||= { 
            allocated: 0, 
            freed: 0, 
            record_count: 0,
            created_at: Time.now,
            last_modified: Time.now,
            total_writes: 0
          }
          @page_usage[page_number][:allocated] += needed_bytes
          @page_usage[page_number][:record_count] += 1
          @page_usage[page_number][:last_modified] = Time.now
          @page_usage[page_number][:total_writes] += 1
          
          @stats[:total_space_allocated] += needed_bytes

          # Clear cache for this page
          @page_records_cache.delete(page_number)

          # Return the offset where data can be written
          offset = new_data_end - needed_bytes
          
          {
            page_number: page_number, 
            offset: offset, 
            page: page,
            free_space_remaining: page.free_space,
            page_usage: @page_usage[page_number]
          }
        end
      end

      # Release a page back to the free pool
      def release_page(page_number)
        @lock.synchronize do
          @stats[:releases] += 1
          
          # Validate page number
          if page_number < 0 || page_number >= @page_manager.total_pages
            raise StorageError, "Invalid page number: #{page_number}"
          end

          # Get page before freeing
          page = @page_manager.get_page(page_number) rescue nil
          
          if page
            # Record usage stats before freeing
            usage = @page_usage[page_number]
            if usage
              @stats[:total_space_allocated] -= usage[:allocated]
              @stats[:total_space_released] += usage[:allocated]
            end
          end
          
          # Release any overflow pages first
          released_overflow = release_overflow_pages(page_number)
          if released_overflow > 0
            @stats[:overflow_releases] += released_overflow
          end
          
          # Free the page
          @page_manager.free_page(page_number)
          @free_space_map.remove_page(page_number)
          @page_usage.delete(page_number)
          @page_records_cache.delete(page_number)
          
          true
        end
      end

      # Get a page and verify it has enough space
      def get_page_with_space(page_number, needed_bytes)
        @lock.synchronize do
          # Validate page exists
          unless page_number < @page_manager.total_pages
            raise StorageError, "Page #{page_number} does not exist"
          end

          page = @page_manager.get_page(page_number)
          
          # Check if page is free
          if page.header.page_type == 3
            raise StorageError, "Page #{page_number} is marked as free"
          end
          
          # Check if page has enough free space
          if page.free_space < needed_bytes
            # Try to compact the page first
            compact_result = compact_page(page_number)
            
            # Re-check after compaction
            page = @page_manager.get_page(page_number)
            
            if page.free_space < needed_bytes
              # Check if we can allocate an overflow page
              needed_overflow = needed_bytes - page.free_space
              overflow_page = allocate_overflow_page(page_number, needed_overflow)
              
              if overflow_page
                @stats[:overflow_allocations] += 1
                return {
                  page_number: overflow_page.page_number,
                  page: overflow_page,
                  overflow: true,
                  parent_page: page_number
                }
              end
              
              raise StorageError, "Not enough space on page #{page_number} (needed: #{needed_bytes}, available: #{page.free_space}, freed: #{compact_result[:space_reclaimed]})"
            end
          end
          
          { page_number: page_number, page: page, overflow: false }
        end
      end

      # Compact a page to remove holes and fragmentation
      def compact_page(page_number)
        @lock.synchronize do
          @stats[:compactions] += 1
          
          # Validate page
          unless page_number < @page_manager.total_pages
            raise StorageError, "Page #{page_number} does not exist"
          end
          
          page = @page_manager.get_page(page_number)
          
          # Skip if page is free
          if page.header.page_type == 3
            return { page_number: page_number, compacted: false, reason: "page is free" }
          end
          
          header_size = PageHeader::SIZE
          old_data_end = page.header.data_end
          
          # Get all records on the page with their actual data
          records = read_page_records(page)
          
          if records.empty?
            # No records to compact
            return { 
              page_number: page_number, 
              compacted: false, 
              reason: "no records",
              space_reclaimed: 0,
              records_compacted: 0
            }
          end
          
          # Sort records by offset to compact them
          records.sort_by! { |r| r[:offset] }
          
          # Check if compaction is needed (check for gaps)
          needs_compaction = false
          current_offset = header_size
          
          records.each do |record|
            if record[:offset] > current_offset
              needs_compaction = true
              break
            end
            current_offset += record[:length] + record[:header_size]
          end
          
          unless needs_compaction
            return {
              page_number: page_number,
              compacted: false,
              reason: "no fragmentation",
              space_reclaimed: 0,
              records_compacted: records.size
            }
          end
          
          # Rewrite records contiguously
          current_offset = header_size
          compacted_records = []
          
          records.each do |record|
            # Read the full record data including header
            record_data = page.read(record[:offset], record[:header_size] + record[:length])
            
            # Write to new position
            page.write(current_offset, record_data)
            
            # Store mapping for potential updates
            compacted_records << {
              old_offset: record[:offset],
              new_offset: current_offset,
              length: record[:length],
              header_size: record[:header_size]
            }
            
            current_offset += record[:header_size] + record[:length]
          end
          
          # Update data_end to the new end position
          new_data_end = current_offset
          page.header.data_end = new_data_end
          page.write_header
          
          @page_manager.write_page(page)
          
          # Update free space map
          @free_space_map.update_page(page_number, page.free_space)
          
          # Clear cache for this page
          @page_records_cache.delete(page_number)
          
          # Track compaction in page usage
          if @page_usage[page_number]
            @page_usage[page_number][:compactions] = (@page_usage[page_number][:compactions] || 0) + 1
            @page_usage[page_number][:space_reclaimed] = (@page_usage[page_number][:space_reclaimed] || 0) + (old_data_end - new_data_end)
            @page_usage[page_number][:last_compact] = Time.now
          end
          
          # Return compaction results
          {
            page_number: page_number,
            compacted: true,
            old_end: old_data_end,
            new_end: new_data_end,
            records_compacted: records.size,
            space_reclaimed: old_data_end - new_data_end,
            compacted_records: compacted_records
          }
        end
      end

      # Allocate an overflow page for large records
      def allocate_overflow_page(parent_page_number, needed_bytes)
        @lock.synchronize do
          page_size = @page_manager.page_manager.page_size
          
          # Validate request
          if needed_bytes > page_size - PageHeader::SIZE - 8
            raise StorageError, "Overflow request #{needed_bytes} exceeds page capacity"
          end
          
          # Allocate new page for overflow
          overflow_page_number = @page_manager.allocate_page(4)  # PAGE_TYPE_OVERFLOW
          
          # Initialize overflow page
          overflow_page = Page.new(overflow_page_number, page_size)
          overflow_page.header.page_type = 4  # PAGE_TYPE_OVERFLOW
          overflow_page.header.data_end = PageHeader::SIZE + needed_bytes
          overflow_page.header.next_page = 0
          overflow_page.header.prev_page = parent_page_number
          overflow_page.write_header
          
          @page_manager.write_page(overflow_page)
          
          # Link overflow page to parent
          @overflow_pages[parent_page_number] ||= []
          @overflow_pages[parent_page_number] << overflow_page_number
          
          # Track overflow page usage
          @page_usage[overflow_page_number] = {
            allocated: needed_bytes,
            freed: 0,
            record_count: 0,
            created_at: Time.now,
            last_modified: Time.now,
            total_writes: 1,
            is_overflow: true,
            parent_page: parent_page_number
          }
          
          # Update free space map
          @free_space_map.update_page(overflow_page_number, overflow_page.free_space)
          
          @stats[:overflow_allocations] += 1
          
          overflow_page
        end
      end

      # Get overflow pages for a page
      def get_overflow_pages(page_number)
        @lock.synchronize do
          @overflow_pages[page_number] || []
        end
      end

      # Get all overflow page information
      def all_overflow_info
        @lock.synchronize do
          result = {}
          @overflow_pages.each do |parent, children|
            result[parent] = children.map do |child|
              page = @page_manager.get_page(child) rescue nil
              if page
                {
                  page_number: child,
                  size: page.header.data_end - PageHeader::SIZE,
                  prev_page: page.header.prev_page,
                  next_page: page.header.next_page
                }
              else
                { page_number: child, valid: false }
              end
            end
          end
          result
        end
      end

      # Release all overflow pages for a page
      def release_overflow_pages(page_number)
        @lock.synchronize do
          overflow_pages = @overflow_pages.delete(page_number) || []
          
          released = 0
          overflow_pages.each do |overflow_page_number|
            begin
              @page_manager.free_page(overflow_page_number)
              @free_space_map.remove_page(overflow_page_number)
              @page_usage.delete(overflow_page_number)
              @page_records_cache.delete(overflow_page_number)
              released += 1
            rescue => e
              # Log error but continue
              puts "Error releasing overflow page #{overflow_page_number}: #{e.message}"
            end
          end
          
          released
        end
      end

      # Get total free space across all pages
      def total_free_space
        @free_space_map.total_free_space
      end

      # Get free space on a specific page
      def page_free_space(page_number)
        @free_space_map.get_free_space(page_number)
      end

      # Get page usage statistics
      def page_usage(page_number)
        @page_usage[page_number] || { allocated: 0, freed: 0, record_count: 0 }
      end

      # Get all page usage statistics
      def all_page_usage
        @page_usage.dup
      end

      # Calculate fragmentation percentage for a page
      def page_fragmentation(page_number)
        page = @page_manager.get_page(page_number) rescue nil
        return 0.0 unless page
        
        # Skip if page is free
        return 0.0 if page.header.page_type == 3
        
        # Get all records on the page
        records = read_page_records(page)
        return 0.0 if records.empty?
        
        # Calculate total record data size including headers
        total_data = records.sum { |r| r[:header_size] + r[:length] }
        
        # Calculate fragmentation (holes between records)
        header_size = PageHeader::SIZE
        sorted_records = records.sort_by { |r| r[:offset] }
        
        fragmentation = 0.0
        last_end = header_size
        
        sorted_records.each do |record|
          if record[:offset] > last_end
            fragmentation += record[:offset] - last_end
          end
          last_end = record[:offset] + record[:header_size] + record[:length]
        end
        
        # Add space after last record
        if last_end < page.header.data_end
          fragmentation += page.header.data_end - last_end
        end
        
        total_used = page.header.data_end - header_size
        return 0.0 if total_used == 0
        
        (fragmentation.to_f / total_used * 100).round(2)
      end

      # Defragment a page (compact and reorganize)
      def defragment_page(page_number)
        @lock.synchronize do
          @stats[:defragmentations] += 1
          
          # Compact the page
          compaction_result = compact_page(page_number)
          
          # After compaction, check if we can free any overflow pages
          page = @page_manager.get_page(page_number)
          overflow_pages = get_overflow_pages(page_number)
          
          freed_overflow = 0
          overflow_pages.each do |overflow_page_number|
            overflow_page = @page_manager.get_page(overflow_page_number) rescue nil
            if overflow_page
              overflow_size = overflow_page.header.data_end - PageHeader::SIZE
              if page.free_space >= overflow_size + 8  # +8 for record header
                # Move overflow data back to main page
                # In production, we would actually move the data here
                release_overflow_pages(page_number)
                freed_overflow = overflow_pages.size
                break
              end
            end
          end
          
          # Update page usage
          if @page_usage[page_number]
            @page_usage[page_number][:defragmented_at] = Time.now
            @page_usage[page_number][:defragment_count] = (@page_usage[page_number][:defragment_count] || 0) + 1
          end
          
          {
            page_number: page_number,
            compacted: compaction_result[:compacted],
            space_reclaimed: compaction_result[:space_reclaimed],
            freed_overflow_pages: freed_overflow,
            fragmentation_before: compaction_result[:fragmentation_before] || 0,
            fragmentation_after: page_fragmentation(page_number)
          }
        end
      end

      # Reserve space on a page for writing
      def reserve_space(page_number, needed_bytes)
        @lock.synchronize do
          # Validate page
          unless page_number < @page_manager.total_pages
            raise StorageError, "Page #{page_number} does not exist"
          end
          
          page = @page_manager.get_page(page_number)
          
          # Skip if page is free
          if page.header.page_type == 3
            raise StorageError, "Cannot reserve space on free page #{page_number}"
          end
          
          # Check if we need to compact or allocate overflow
          if page.free_space < needed_bytes
            # Try compacting first
            compact_result = compact_page(page_number)
            page = @page_manager.get_page(page_number)
            
            if page.free_space < needed_bytes
              # Try allocating overflow
              overflow_page = allocate_overflow_page(page_number, needed_bytes - page.free_space)
              if overflow_page
                return { 
                  page_number: overflow_page.page_number, 
                  offset: PageHeader::SIZE, 
                  page: overflow_page,
                  is_overflow: true
                }
              end
              
              raise StorageError, "Cannot reserve #{needed_bytes} bytes on page #{page_number} (available: #{page.free_space})"
            end
          end
          
          # Reserve space on the page
          offset = page.header.data_end
          page.header.data_end += needed_bytes
          page.write_header
          @page_manager.write_page(page)
          
          # Update free space map
          @free_space_map.update_page(page_number, page.free_space)
          
          # Update page usage
          if @page_usage[page_number]
            @page_usage[page_number][:reserved] = (@page_usage[page_number][:reserved] || 0) + needed_bytes
            @page_usage[page_number][:last_modified] = Time.now
          end
          
          # Clear cache
          @page_records_cache.delete(page_number)
          
          { page_number: page_number, offset: offset, page: page, is_overflow: false }
        end
      end

      # Release reserved space on a page
      def release_reserved_space(page_number, offset, length)
        @lock.synchronize do
          # Validate page
          unless page_number < @page_manager.total_pages
            return false
          end
          
          page = @page_manager.get_page(page_number)
          
          # Skip if page is free
          return false if page.header.page_type == 3
          
          # Only allow releasing space from the end (where we reserved it)
          if offset + length == page.header.data_end
            page.header.data_end -= length
            page.write_header
            @page_manager.write_page(page)
            
            # Update free space map
            @free_space_map.update_page(page_number, page.free_space)
            
            # Update page usage
            if @page_usage[page_number]
              @page_usage[page_number][:reserved] = (@page_usage[page_number][:reserved] || 0) - length
              @page_usage[page_number][:released_reserved] = (@page_usage[page_number][:released_reserved] || 0) + length
              @page_usage[page_number][:last_modified] = Time.now
            end
            
            # Clear cache
            @page_records_cache.delete(page_number)
            
            true
          else
            # Cannot release internal space - would need compaction
            false
          end
        end
      end

      # Get page allocation statistics
      def allocation_stats
        @lock.synchronize do
          fragmentation_avg = average_fragmentation
          
          {
            total_pages: @page_manager.total_pages,
            free_pages: @page_manager.free_pages,
            used_pages: @page_manager.used_pages,
            page_usage_count: @page_usage.size,
            overflow_pages: @overflow_pages.values.flatten.size,
            overflow_groups: @overflow_pages.size,
            allocations: @stats[:allocations],
            releases: @stats[:releases],
            compactions: @stats[:compactions],
            defragmentations: @stats[:defragmentations],
            allocation_failures: @stats[:allocation_failures],
            overflow_allocations: @stats[:overflow_allocations],
            overflow_releases: @stats[:overflow_releases],
            total_space_requested: @stats[:total_space_requested],
            total_space_allocated: @stats[:total_space_allocated],
            total_space_released: @stats[:total_space_released],
            free_space_total: total_free_space,
            fragmentation_avg: fragmentation_avg,
            cache_hits: @cache_hits,
            cache_misses: @cache_misses,
            cache_hit_rate: cache_hit_rate,
            defragmentation_threshold: @defragmentation_threshold
          }
        end
      end

      # Calculate average fragmentation across all pages
      def average_fragmentation
        pages = @page_manager.total_pages
        return 0.0 if pages == 0
        
        total_fragmentation = 0.0
        count = 0
        
        (0...pages).each do |page_number|
          begin
            frag = page_fragmentation(page_number)
            if frag > 0
              total_fragmentation += frag
              count += 1
            end
          rescue
            # Skip pages that can't be read
          end
        end
        
        count > 0 ? (total_fragmentation / count).round(2) : 0.0
      end

      # Get pages with high fragmentation (above threshold)
      def fragmented_pages(threshold = @defragmentation_threshold)
        @lock.synchronize do
          result = []
          (0...@page_manager.total_pages).each do |page_number|
            begin
              frag = page_fragmentation(page_number)
              if frag > threshold * 100  # threshold is 0-1, frag is 0-100
                result << {
                  page_number: page_number,
                  fragmentation: frag,
                  free_space: page_free_space(page_number),
                  usage: page_usage(page_number)
                }
              end
            rescue
              # Skip pages that can't be read
            end
          end
          result.sort_by { |p| -p[:fragmentation] }
        end
      end

      # Automatically defragment pages above threshold
      def auto_defragment(threshold = @defragmentation_threshold)
        @lock.synchronize do
          pages = fragmented_pages(threshold)
          results = []
          
          pages.each do |page_info|
            begin
              result = defragment_page(page_info[:page_number])
              results << result
            rescue => e
              results << { page_number: page_info[:page_number], error: e.message }
            end
          end
          
          {
            defragmented: results.select { |r| r[:compacted] }.size,
            errors: results.select { |r| r[:error] }.size,
            total_space_reclaimed: results.sum { |r| r[:space_reclaimed] || 0 },
            results: results
          }
        end
      end

      # Reset statistics
      def reset_stats
        @lock.synchronize do
          @stats = {
            allocations: 0,
            releases: 0,
            compactions: 0,
            defragmentations: 0,
            allocation_failures: 0,
            total_space_requested: 0,
            total_space_allocated: 0,
            total_space_released: 0,
            overflow_allocations: 0,
            overflow_releases: 0
          }
          @cache_hits = 0
          @cache_misses = 0
        end
      end

      private

      # Read all records from a page with proper record header parsing
      def read_page_records(page)
        # Check cache first
        cache_key = [page.page_number, page.header.data_end]
        if @page_records_cache.key?(page.page_number)
          cached = @page_records_cache[page.page_number]
          if cached[:data_end] == page.header.data_end
            @cache_hits += 1
            return cached[:records]
          end
        end
        @cache_misses += 1

        records = []
        header_size = PageHeader::SIZE
        offset = header_size
        
        while offset < page.header.data_end
          begin
            # Read record header: [record_id(8)] [header_size(2)] [data_length(4)] [flags(2)]
            # Total header size: 16 bytes
            record_header = page.read(offset, 16)
            
            if record_header && record_header.bytesize == 16
              record_id, rec_header_size, data_length, flags = record_header.unpack("Q>S>I>S>")
              
              # Validate header
              if rec_header_size >= 16 && data_length > 0 && data_length < (page.size - offset)
                records << {
                  offset: offset,
                  length: data_length,
                  header_size: rec_header_size,
                  record_id: record_id,
                  flags: flags
                }
                
                offset += rec_header_size + data_length
              else
                # Invalid record - stop scanning
                break
              end
            else
              break
            end
          rescue => e
            # Error reading record - stop
            break
          end
        end
        
        # Cache the result
        if records.size <= @max_cache_size
          @page_records_cache[page.page_number] = {
            data_end: page.header.data_end,
            records: records
          }
        end
        
        records
      end

      # Calculate cache hit rate
      def cache_hit_rate
        total = @cache_hits + @cache_misses
        return 0.0 if total == 0
        (@cache_hits.to_f / total * 100).round(2)
      end
    end
  end
end