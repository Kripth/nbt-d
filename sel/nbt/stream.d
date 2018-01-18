﻿/*
 * Copyright (c) 2017-2018 SEL
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU Lesser General Public License for more details.
 * 
 */
module sel.nbt.stream;

import std.bitmanip : littleEndianToNative, bigEndianToNative, nativeToLittleEndian, nativeToBigEndian;
import std.string : capitalize, toUpper;
import std.system : Endian;

import sel.nbt.tags;

private pure nothrow @safe ubyte[] write(T, Endian endianness)(T value) {
	mixin("return nativeTo" ~ endianString(endianness)[0..1].toUpper ~ endianString(endianness)[1..$] ~ "!T(value).dup;");
}

private pure nothrow @safe T read(T, Endian endianness)(ref ubyte[] buffer) {
	if(buffer.length >= T.sizeof) {
		ubyte[T.sizeof] b = buffer[0..T.sizeof];
		buffer = buffer[T.sizeof..$];
		mixin("return " ~ endianString(endianness) ~ "ToNative!T(b);");
	} else if(buffer.length) {
		buffer.length = T.sizeof;
		return read!(T, endianness)(buffer);
	} else {
		return T.init;
	}
}

private pure nothrow @safe string endianString(Endian endianness) {
	return endianness == Endian.littleEndian ? "littleEndian" : "bigEndian";
}

struct Options {
	
	size_t maxLength = int.max;
	size_t maxCompoundLength = int.max;
	
};

class Stream {

	public ubyte[] buffer;

	public Options options;
	
	public pure nothrow @safe @nogc this(ubyte[] buffer=[], Options options=Options.init) {
		this.buffer = buffer;
		this.options = options;
	}

	public pure nothrow @safe void writeNamelessTag(Tag tag) {
		this.writeByte(tag.type);
		tag.encode(this);
	}

	public pure nothrow @safe void writeTag(Tag tag) {
		this.writeByte(tag.type);
		this.writeString(tag.name);
		tag.encode(this);
	}

	public abstract pure nothrow @safe void writeByte(byte value);

	public abstract pure nothrow @safe void writeShort(short value);

	public abstract pure nothrow @safe void writeInt(int value);

	public abstract pure nothrow @safe void writeLong(long value);

	public abstract pure nothrow @safe void writeFloat(float value);

	public abstract pure nothrow @safe void writeDouble(double value);

	public abstract pure nothrow @safe void writeString(string value);

	public abstract pure nothrow @safe void writeLength(size_t value);

	public pure nothrow @safe Tag readNamelessTag() {
		switch(this.readByte()) {
			foreach(i, T; Tags) {
				static if(is(T : Tag)) {
					case i: return this.decodeTagImpl(new T());
				}
			}
			default: return null;
		}
	}

	public pure nothrow @safe Tag readTag() {
		switch(this.readByte()) {
			foreach(i, T; Tags) {
				static if(is(T : Tag)) {
					case i: return this.decodeTagImpl(new Named!T(this.readString()));
				}
			}
			default: return null;
		}
	}

	public pure nothrow @safe T decodeTagImpl(T:Tag)(T tag) {
		tag.decode(this);
		return tag;
	}

	public abstract pure nothrow @safe byte readByte();

	public abstract pure nothrow @safe short readShort();

	public abstract pure nothrow @safe int readInt();

	public abstract pure nothrow @safe long readLong();

	public abstract pure nothrow @safe float readFloat();

	public abstract pure nothrow @safe double readDouble();

	public abstract pure nothrow @safe string readString();

	public abstract pure nothrow @safe size_t readLength();

}

class ClassicStream(Endian endianness) : Stream {
	
	public pure nothrow @safe @nogc this(ubyte[] buffer=[], Options options=Options.init) {
		super(buffer, options);
	}

	private mixin template Impl(T) {

		mixin("public override pure nothrow @safe void write" ~ capitalize(T.stringof) ~ "(T value){ this.buffer ~= write!(T, endianness)(value); }");

		mixin("public override pure nothrow @safe T read" ~ capitalize(T.stringof) ~ "(){ return read!(T, endianness)(this.buffer); }");

	}

	mixin Impl!byte;

	mixin Impl!short;

	mixin Impl!int;

	mixin Impl!long;

	mixin Impl!float;

	mixin Impl!double;

	public override pure nothrow @trusted void writeString(string value) {
		this.writeStringLength(value.length);
		this.buffer ~= cast(ubyte[])value;
	}

	protected pure nothrow @safe void writeStringLength(size_t value) {
		this.writeShort(value & short.max);
	}

	public override pure nothrow @safe void writeLength(size_t value) {
		this.writeInt(value & int.max);
	}
	
	public override pure nothrow @trusted string readString() {
		immutable length = this.readStringLength();
		if(this.buffer.length < length) this.buffer.length = length;
		auto ret = this.buffer[0..length];
		this.buffer = this.buffer[length..$];
		return cast(string)ret;
	}

	protected pure nothrow @safe size_t readStringLength() {
		return this.readShort();
	}

	public override pure nothrow @safe size_t readLength() {
		return this.readInt();
	}

}

class NetworkStream(Endian endianness) : ClassicStream!(endianness) {

	public pure nothrow @safe @nogc this(ubyte[] buffer=[], Options options=Options.init) {
		super(buffer, options);
	}

	public override pure nothrow @safe void writeInt(int value) {
		this.writeLength(value >= 0 ? value * 2 : value * -2 - 1);
	}

	protected override pure nothrow @safe void writeStringLength(size_t value) {
		this.writeLength(value);
	}
	
	public override pure nothrow @safe void writeLength(size_t value) {
		value &= 0x7FFFFFFF;
		while(value > 0x7F) {
			this.buffer ~= value & 0x7F | 0x80;
			value >>= 7;
		}
		this.buffer ~= value & 0x7F;
	}

	public override pure nothrow @safe int readInt() {
		uint ret = cast(uint)this.readLength();
		if(ret & 1) return (-1 - cast(int)ret) / 2;
		else return ret / 2;
	}

	protected override pure nothrow @safe size_t readStringLength() {
		return this.readLength();
	}

	public override pure nothrow @safe size_t readLength() {
		size_t ret = 0;
		ubyte next, limit;
		do {
			next = read!(ubyte, endianness)(this.buffer);
			ret |= (next & 0x7F) << (limit++ * 7);
		} while(limit < 5 && (next & 0x80));
		return ret;
	}

}