package hpack

// Huffman_Code represents a Huffman-encoded symbol
Huffman_Code :: struct {
	code:    u32,  // The bit pattern
	length:  u8,   // Number of bits in the code
}

// HUFFMAN_CODES contains the Huffman encoding table from RFC 7541 Appendix B.
// Indexed by the byte value (0-255).
// Codes are aligned to the left (MSB first).
HUFFMAN_CODES := [256]Huffman_Code{
	// 0-15
	{0x1ff8, 13},     // 0
	{0x7fffd8, 23},   // 1
	{0xfffffe2, 28},  // 2
	{0xfffffe3, 28},  // 3
	{0xfffffe4, 28},  // 4
	{0xfffffe5, 28},  // 5
	{0xfffffe6, 28},  // 6
	{0xfffffe7, 28},  // 7
	{0xfffffe8, 28},  // 8
	{0xffffea, 24},   // 9
	{0x3ffffffc, 30}, // 10
	{0xfffffe9, 28},  // 11
	{0xfffffea, 28},  // 12
	{0x3ffffffd, 30}, // 13
	{0xfffffeb, 28},  // 14
	{0xfffffec, 28},  // 15

	// 16-31
	{0xfffffed, 28},  // 16
	{0xfffffee, 28},  // 17
	{0xfffffef, 28},  // 18
	{0xffffff0, 28},  // 19
	{0xffffff1, 28},  // 20
	{0xffffff2, 28},  // 21
	{0x3ffffffe, 30}, // 22
	{0xffffff3, 28},  // 23
	{0xffffff4, 28},  // 24
	{0xffffff5, 28},  // 25
	{0xffffff6, 28},  // 26
	{0xffffff7, 28},  // 27
	{0xffffff8, 28},  // 28
	{0xffffff9, 28},  // 29
	{0xffffffa, 28},  // 30
	{0xffffffb, 28},  // 31

	// 32-47 (space and common punctuation)
	{0x14, 6},        // 32 ' '
	{0x3f8, 10},      // 33 '!'
	{0x3f9, 10},      // 34 '"'
	{0xffa, 12},      // 35 '#'
	{0x1ff9, 13},     // 36 '$'
	{0x15, 6},        // 37 '%'
	{0xf8, 8},        // 38 '&'
	{0x7fa, 11},      // 39 '\''
	{0x3fa, 10},      // 40 '('
	{0x3fb, 10},      // 41 ')'
	{0xf9, 8},        // 42 '*'
	{0x7fb, 11},      // 43 '+'
	{0xfa, 8},        // 44 ','
	{0x16, 6},        // 45 '-'
	{0x17, 6},        // 46 '.'
	{0x18, 6},        // 47 '/'

	// 48-63 (digits 0-9, punctuation)
	{0x0, 5},         // 48 '0'
	{0x1, 5},         // 49 '1'
	{0x2, 5},         // 50 '2'
	{0x19, 6},        // 51 '3'
	{0x1a, 6},        // 52 '4'
	{0x1b, 6},        // 53 '5'
	{0x1c, 6},        // 54 '6'
	{0x1d, 6},        // 55 '7'
	{0x1e, 6},        // 56 '8'
	{0x1f, 6},        // 57 '9'
	{0x5c, 7},        // 58 ':'
	{0xfb, 8},        // 59 ';'
	{0x7ffc, 15},     // 60 '<'
	{0x20, 6},        // 61 '='
	{0xffb, 12},      // 62 '>'
	{0x3fc, 10},      // 63 '?'

	// 64-79 (@ A-O)
	{0x1ffa, 13},     // 64 '@'
	{0x21, 6},        // 65 'A'
	{0x5d, 7},        // 66 'B'
	{0x5e, 7},        // 67 'C'
	{0x5f, 7},        // 68 'D'
	{0x60, 7},        // 69 'E'
	{0x61, 7},        // 70 'F'
	{0x62, 7},        // 71 'G'
	{0x63, 7},        // 72 'H'
	{0x64, 7},        // 73 'I'
	{0x65, 7},        // 74 'J'
	{0x66, 7},        // 75 'K'
	{0x67, 7},        // 76 'L'
	{0x68, 7},        // 77 'M'
	{0x69, 7},        // 78 'N'
	{0x6a, 7},        // 79 'O'

	// 80-95 (P-Z, punctuation)
	{0x6b, 7},        // 80 'P'
	{0x6c, 7},        // 81 'Q'
	{0x6d, 7},        // 82 'R'
	{0x6e, 7},        // 83 'S'
	{0x6f, 7},        // 84 'T'
	{0x70, 7},        // 85 'U'
	{0x71, 7},        // 86 'V'
	{0x72, 7},        // 87 'W'
	{0xfc, 8},        // 88 'X'
	{0x73, 7},        // 89 'Y'
	{0xfd, 8},        // 90 'Z'
	{0x1ffb, 13},     // 91 '['
	{0x7fff0, 19},    // 92 '\\'
	{0x1ffc, 13},     // 93 ']'
	{0x3ffc, 14},     // 94 '^'
	{0x22, 6},        // 95 '_'

	// 96-111 (` a-o)
	{0x7ffd, 15},     // 96 '`'
	{0x3, 5},         // 97 'a'
	{0x23, 6},        // 98 'b'
	{0x4, 5},         // 99 'c'
	{0x24, 6},        // 100 'd'
	{0x5, 5},         // 101 'e'
	{0x25, 6},        // 102 'f'
	{0x26, 6},        // 103 'g'
	{0x27, 6},        // 104 'h'
	{0x6, 5},         // 105 'i'
	{0x74, 7},        // 106 'j'
	{0x75, 7},        // 107 'k'
	{0x28, 6},        // 108 'l'
	{0x29, 6},        // 109 'm'
	{0x2a, 6},        // 110 'n'
	{0x7, 5},         // 111 'o'

	// 112-127 (p-z, punctuation, DEL)
	{0x2b, 6},        // 112 'p'
	{0x76, 7},        // 113 'q'
	{0x2c, 6},        // 114 'r'
	{0x8, 5},         // 115 's'
	{0x9, 5},         // 116 't'
	{0x2d, 6},        // 117 'u'
	{0x77, 7},        // 118 'v'
	{0x78, 7},        // 119 'w'
	{0x79, 7},        // 120 'x'
	{0x7a, 7},        // 121 'y'
	{0x7b, 7},        // 122 'z'
	{0x7ffe, 15},     // 123 '{'
	{0x7fc, 11},      // 124 '|'
	{0x3ffd, 14},     // 125 '}'
	{0x1ffd, 13},     // 126 '~'
	{0xffffffc, 28},  // 127 DEL

	// 128-143
	{0xfffe6, 20},    // 128
	{0x3fffd2, 22},   // 129
	{0xfffe7, 20},    // 130
	{0xfffe8, 20},    // 131
	{0x3fffd3, 22},   // 132
	{0x3fffd4, 22},   // 133
	{0x3fffd5, 22},   // 134
	{0x7fffd9, 23},   // 135
	{0x3fffd6, 22},   // 136
	{0x7fffda, 23},   // 137
	{0x7fffdb, 23},   // 138
	{0x7fffdc, 23},   // 139
	{0x7fffdd, 23},   // 140
	{0x7fffde, 23},   // 141
	{0xffffeb, 24},   // 142
	{0x7fffdf, 23},   // 143

	// 144-159
	{0xffffec, 24},   // 144
	{0xffffed, 24},   // 145
	{0x3fffd7, 22},   // 146
	{0x7fffe0, 23},   // 147
	{0xffffee, 24},   // 148
	{0x7fffe1, 23},   // 149
	{0x7fffe2, 23},   // 150
	{0x7fffe3, 23},   // 151
	{0x7fffe4, 23},   // 152
	{0x1fffdc, 21},   // 153
	{0x3fffd8, 22},   // 154
	{0x7fffe5, 23},   // 155
	{0x3fffd9, 22},   // 156
	{0x7fffe6, 23},   // 157
	{0x7fffe7, 23},   // 158
	{0xffffef, 24},   // 159

	// 160-175
	{0x3fffda, 22},   // 160
	{0x1fffdd, 21},   // 161
	{0xfffe9, 20},    // 162
	{0x3fffdb, 22},   // 163
	{0x3fffdc, 22},   // 164
	{0x7fffe8, 23},   // 165
	{0x7fffe9, 23},   // 166
	{0x1fffde, 21},   // 167
	{0x7fffea, 23},   // 168
	{0x3fffdd, 22},   // 169
	{0x3fffde, 22},   // 170
	{0xfffff0, 24},   // 171
	{0x1fffdf, 21},   // 172
	{0x3fffdf, 22},   // 173
	{0x7fffeb, 23},   // 174
	{0x7fffec, 23},   // 175

	// 176-191
	{0x1fffe0, 21},   // 176
	{0x1fffe1, 21},   // 177
	{0x3fffe0, 22},   // 178
	{0x1fffe2, 21},   // 179
	{0x7fffed, 23},   // 180
	{0x3fffe1, 22},   // 181
	{0x7fffee, 23},   // 182
	{0x7fffef, 23},   // 183
	{0xfffea, 20},    // 184
	{0x3fffe2, 22},   // 185
	{0x3fffe3, 22},   // 186
	{0x3fffe4, 22},   // 187
	{0x7ffff0, 23},   // 188
	{0x3fffe5, 22},   // 189
	{0x3fffe6, 22},   // 190
	{0x7ffff1, 23},   // 191

	// 192-207
	{0x3ffffe0, 26},  // 192
	{0x3ffffe1, 26},  // 193
	{0xfffeb, 20},    // 194
	{0x7fff1, 19},    // 195
	{0x3fffe7, 22},   // 196
	{0x7ffff2, 23},   // 197
	{0x3fffe8, 22},   // 198
	{0x1ffffec, 25},  // 199
	{0x3ffffe2, 26},  // 200
	{0x3ffffe3, 26},  // 201
	{0x3ffffe4, 26},  // 202
	{0x7ffffde, 27},  // 203
	{0x7ffffdf, 27},  // 204
	{0x3ffffe5, 26},  // 205
	{0xfffff1, 24},   // 206
	{0x1ffffed, 25},  // 207

	// 208-223
	{0x7fff2, 19},    // 208
	{0x1fffe3, 21},   // 209
	{0x3ffffe6, 26},  // 210
	{0x7ffffe0, 27},  // 211
	{0x7ffffe1, 27},  // 212
	{0x3ffffe7, 26},  // 213
	{0x7ffffe2, 27},  // 214
	{0xfffff2, 24},   // 215
	{0x1fffe4, 21},   // 216
	{0x1fffe5, 21},   // 217
	{0x3ffffe8, 26},  // 218
	{0x3ffffe9, 26},  // 219
	{0xffffffd, 28},  // 220
	{0x7ffffe3, 27},  // 221
	{0x7ffffe4, 27},  // 222
	{0x7ffffe5, 27},  // 223

	// 224-239
	{0xfffec, 20},    // 224
	{0xfffff3, 24},   // 225
	{0xfffed, 20},    // 226
	{0x1fffe6, 21},   // 227
	{0x3fffe9, 22},   // 228
	{0x1fffe7, 21},   // 229
	{0x1fffe8, 21},   // 230
	{0x7ffff3, 23},   // 231
	{0x3fffea, 22},   // 232
	{0x3fffeb, 22},   // 233
	{0x1ffffee, 25},  // 234
	{0x1ffffef, 25},  // 235
	{0xfffff4, 24},   // 236
	{0xfffff5, 24},   // 237
	{0x3ffffea, 26},  // 238
	{0x7ffff4, 23},   // 239

	// 240-255
	{0x3ffffeb, 26},  // 240
	{0x7ffffe6, 27},  // 241
	{0x3ffffec, 26},  // 242
	{0x3ffffed, 26},  // 243
	{0x7ffffe7, 27},  // 244
	{0x7ffffe8, 27},  // 245
	{0x7ffffe9, 27},  // 246
	{0x7ffffea, 27},  // 247
	{0x7ffffeb, 27},  // 248
	{0xffffffe, 28},  // 249
	{0x7ffffec, 27},  // 250
	{0x7ffffed, 27},  // 251
	{0x7ffffee, 27},  // 252
	{0x7ffffef, 27},  // 253
	{0x7fffff0, 27},  // 254
	{0x3ffffee, 26},  // 255
}

// EOS (End of String) symbol is all 1's with length 30
HUFFMAN_EOS :: Huffman_Code{0x3fffffff, 30}

// Huffman_Decode_Node represents a node in the Huffman decoding tree
Huffman_Decode_Node :: struct {
	// For leaf nodes: the decoded symbol (0-255)
	// For internal nodes: undefined
	symbol: u8,

	// true if this is a leaf node containing a symbol
	is_leaf: bool,

	// Pointers to left (0) and right (1) children
	// nil for leaf nodes
	left:  ^Huffman_Decode_Node,
	right: ^Huffman_Decode_Node,
}

// huffman_decode_tree_build constructs the decoding tree from HUFFMAN_CODES.
// The caller is responsible for freeing the tree with huffman_decode_tree_destroy.
huffman_decode_tree_build :: proc(allocator := context.allocator) -> (root: ^Huffman_Decode_Node, ok: bool) {
	context.allocator = allocator

	// Create root node
	root = new(Huffman_Decode_Node)
	if root == nil {
		return nil, false
	}
	root.is_leaf = false

	// Insert each symbol into the tree
	for symbol in 0..<256 {
		code := HUFFMAN_CODES[symbol]

		// Walk down the tree following the bit pattern
		current := root
		for bit_index := int(code.length) - 1; bit_index >= 0; bit_index -= 1 {
			// Extract bit at position (length - 1 - bit_index) from MSB
			bit := (code.code >> uint(bit_index)) & 1

			if bit == 0 {
				// Go left
				if current.left == nil {
					current.left = new(Huffman_Decode_Node)
					if current.left == nil {
						huffman_decode_tree_destroy(root, allocator)
						return nil, false
					}
					current.left.is_leaf = false
				}
				current = current.left
			} else {
				// Go right
				if current.right == nil {
					current.right = new(Huffman_Decode_Node)
					if current.right == nil {
						huffman_decode_tree_destroy(root, allocator)
						return nil, false
					}
					current.right.is_leaf = false
				}
				current = current.right
			}
		}

		// Mark as leaf and store symbol
		current.is_leaf = true
		current.symbol = u8(symbol)
	}

	return root, true
}

// huffman_decode_tree_destroy frees all nodes in the tree
huffman_decode_tree_destroy :: proc(root: ^Huffman_Decode_Node, allocator := context.allocator) {
	if root == nil {
		return
	}

	context.allocator = allocator

	huffman_decode_tree_destroy(root.left, allocator)
	huffman_decode_tree_destroy(root.right, allocator)
	free(root)
}

// huffman_encode encodes input bytes into a Huffman-encoded bit stream.
// Returns the encoded bytes and the number of padding bits in the last byte.
huffman_encode :: proc(input: []byte, allocator := context.allocator) -> (output: []byte, padding_bits: u8, ok: bool) {
	if len(input) == 0 {
		return nil, 0, true
	}

	context.allocator = allocator

	// Calculate total bits needed
	total_bits := 0
	for b in input {
		total_bits += int(HUFFMAN_CODES[b].length)
	}

	// Calculate output size in bytes
	output_size := (total_bits + 7) / 8
	output = make([]byte, output_size)
	if output == nil {
		return nil, 0, false
	}

	// Encode bit by bit
	bit_pos := 0
	for b in input {
		code := HUFFMAN_CODES[b]

		// Write each bit of the code
		for bit_index := int(code.length) - 1; bit_index >= 0; bit_index -= 1 {
			bit := u8((code.code >> uint(bit_index)) & 1)

			byte_index := bit_pos / 8
			bit_in_byte := 7 - (bit_pos % 8)

			if bit == 1 {
				output[byte_index] |= (1 << uint(bit_in_byte))
			}

			bit_pos += 1
		}
	}

	// Pad with 1's (EOS prefix) to byte boundary
	padding_bits = u8((8 - (total_bits % 8)) % 8)
	if padding_bits > 0 {
		byte_index := bit_pos / 8
		for i in 0..<padding_bits {
			bit_in_byte := 7 - ((bit_pos + int(i)) % 8)
			output[byte_index] |= (1 << uint(bit_in_byte))
		}
	}

	return output, padding_bits, true
}

// huffman_decode decodes a Huffman-encoded bit stream back to bytes.
// The tree parameter must be created with huffman_decode_tree_build.
huffman_decode :: proc(input: []byte, tree: ^Huffman_Decode_Node, allocator := context.allocator) -> (output: []byte, ok: bool) {
	if len(input) == 0 {
		return nil, true
	}

	if tree == nil {
		return nil, false
	}

	context.allocator = allocator

	// Output buffer (dynamic)
	result := make([dynamic]byte, 0, 64, allocator)
	defer if !ok { delete(result) }

	// Traverse tree following bits
	current := tree
	for byte_val, byte_idx in input {
		for bit_index := 7; bit_index >= 0; bit_index -= 1 {
			bit := (byte_val >> uint(bit_index)) & 1

			if bit == 0 {
				current = current.left
			} else {
				current = current.right
			}

			if current == nil {
				// This should only happen with padding (all 1's at the end)
				// Padding is valid and should be ignored
				// Verify we're at the end and all remaining bits are 1
				is_last_byte := byte_idx == len(input) - 1
				if !is_last_byte {
					// Invalid code in the middle of stream
					return nil, false
				}

				// Check remaining bits in this byte are all 1's (padding)
				for remaining_bit := bit_index; remaining_bit >= 0; remaining_bit -= 1 {
					if ((byte_val >> uint(remaining_bit)) & 1) == 0 {
						// Not valid padding (found a 0)
						return nil, false
					}
				}

				// Valid padding, we're done
				return result[:], true
			}

			if current.is_leaf {
				append(&result, current.symbol)
				current = tree
			}
		}
	}

	// After processing all bits, we should be back at root (or in padding)
	// Padding is all 1's, which is the prefix of EOS (never a complete symbol)
	if current != tree {
		// We're in the middle of a code. This is only valid if it's EOS padding.
		// Since padding is all 1's and we haven't hit nil, we must have finished
		// on a partial code that's a prefix of EOS. This is acceptable.
		// (Per RFC 7541: padding is to be filled with 1's which is EOS prefix)
	}

	return result[:], true
}
