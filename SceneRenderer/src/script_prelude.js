// The SceneScript environment: the globals a scene script expects, written for this renderer.
// The API surface (names and behaviour) follows Wallpaper Engine's public SceneScript
// documentation and the scripts found in real scenes. The host talks to this file through the
// `__wm_*` functions only, always with JSON strings.
'use strict';

function __num(v, d) {
	const n = Number(v);
	return Number.isFinite(n) ? n : d;
}

class Vec2 {
	constructor(x, y) {
		if (x !== null && typeof x === 'object') { y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
	}
	copy() { return new Vec2(this.x, this.y); }
	add(o) { o = __vec2(o); return new Vec2(this.x + o.x, this.y + o.y); }
	subtract(o) { o = __vec2(o); return new Vec2(this.x - o.x, this.y - o.y); }
	multiply(o) { o = __vec2(o); return new Vec2(this.x * o.x, this.y * o.y); }
	divide(o) { o = __vec2(o); return new Vec2(this.x / o.x, this.y / o.y); }
	dot(o) { o = __vec2(o); return this.x * o.x + this.y * o.y; }
	length() { return Math.sqrt(this.x * this.x + this.y * this.y); }
	lengthSqr() { return this.x * this.x + this.y * this.y; }
	normalize() { const l = this.length(); return l > 0 ? new Vec2(this.x / l, this.y / l) : new Vec2(0, 0); }
	mix(o, t) { o = __vec2(o); return new Vec2(this.x + (o.x - this.x) * t, this.y + (o.y - this.y) * t); }
	perpendicular() { return new Vec2(-this.y, this.x); }
	reflect(n) { n = __vec2(n); const d = 2 * this.dot(n); return new Vec2(this.x - d * n.x, this.y - d * n.y); }
	equals(o) { o = __vec2(o); return this.x === o.x && this.y === o.y; }
	toString() { return `${this.x} ${this.y}`; }
	static fromString(s) { const p = String(s).trim().split(/\s+/).map(Number); return new Vec2(p[0], p[1] === undefined ? p[0] : p[1]); }
}

class Vec3 {
	constructor(x, y, z) {
		if (x !== null && typeof x === 'object') { z = x.z; y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
		this.z = z === undefined ? (y === undefined ? this.x : 0) : __num(z, 0);
	}
	copy() { return new Vec3(this.x, this.y, this.z); }
	add(o) { o = __vec3(o); return new Vec3(this.x + o.x, this.y + o.y, this.z + o.z); }
	subtract(o) { o = __vec3(o); return new Vec3(this.x - o.x, this.y - o.y, this.z - o.z); }
	multiply(o) { o = __vec3(o); return new Vec3(this.x * o.x, this.y * o.y, this.z * o.z); }
	divide(o) { o = __vec3(o); return new Vec3(this.x / o.x, this.y / o.y, this.z / o.z); }
	dot(o) { o = __vec3(o); return this.x * o.x + this.y * o.y + this.z * o.z; }
	cross(o) { o = __vec3(o); return new Vec3(this.y * o.z - this.z * o.y, this.z * o.x - this.x * o.z, this.x * o.y - this.y * o.x); }
	length() { return Math.sqrt(this.lengthSqr()); }
	lengthSqr() { return this.x * this.x + this.y * this.y + this.z * this.z; }
	normalize() { const l = this.length(); return l > 0 ? new Vec3(this.x / l, this.y / l, this.z / l) : new Vec3(0, 0, 0); }
	mix(o, t) { o = __vec3(o); return new Vec3(this.x + (o.x - this.x) * t, this.y + (o.y - this.y) * t, this.z + (o.z - this.z) * t); }
	reflect(n) { n = __vec3(n); const d = 2 * this.dot(n); return new Vec3(this.x - d * n.x, this.y - d * n.y, this.z - d * n.z); }
	equals(o) { o = __vec3(o); return this.x === o.x && this.y === o.y && this.z === o.z; }
	toString() { return `${this.x} ${this.y} ${this.z}`; }
	static fromString(s) { const p = String(s).trim().split(/\s+/).map(Number); return new Vec3(p[0], p[1] === undefined ? p[0] : p[1], p[2] === undefined ? (p[1] === undefined ? p[0] : 0) : p[2]); }
}

class Vec4 {
	constructor(x, y, z, w) {
		if (x !== null && typeof x === 'object') { w = x.w; z = x.z; y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
		this.z = z === undefined ? this.x : __num(z, 0);
		this.w = w === undefined ? this.x : __num(w, 0);
	}
	copy() { return new Vec4(this.x, this.y, this.z, this.w); }
	toString() { return `${this.x} ${this.y} ${this.z} ${this.w}`; }
}

function __vec2(o) { return typeof o === 'number' ? new Vec2(o, o) : o; }
function __vec3(o) { return typeof o === 'number' ? new Vec3(o, o, o) : o; }

// 4x4 matrices as Wallpaper Engine's puppet calls hand them out: row vectors (a point is
// multiplied from the left), `m` in memory order, the translation in m[12..14]; angles in
// degrees. `a.multiply(b)` applies a, then b.
function __mul4(a, b) {
	const r = new Array(16);
	for (let i = 0; i < 4; i++) {
		for (let j = 0; j < 4; j++) {
			let sum = 0;
			for (let k = 0; k < 4; k++) sum += a[i * 4 + k] * b[k * 4 + j];
			r[i * 4 + j] = sum;
		}
	}
	return r;
}
function __inv4(m) {
	const a = m.slice(), r = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
	for (let c = 0; c < 4; c++) {
		let p = c;
		for (let i = c + 1; i < 4; i++) if (Math.abs(a[i * 4 + c]) > Math.abs(a[p * 4 + c])) p = i;
		if (Math.abs(a[p * 4 + c]) < 1e-12) return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
		for (let k = 0; k < 4; k++) {
			[a[c * 4 + k], a[p * 4 + k]] = [a[p * 4 + k], a[c * 4 + k]];
			[r[c * 4 + k], r[p * 4 + k]] = [r[p * 4 + k], r[c * 4 + k]];
		}
		const d = a[c * 4 + c];
		for (let k = 0; k < 4; k++) { a[c * 4 + k] /= d; r[c * 4 + k] /= d; }
		for (let i = 0; i < 4; i++) {
			if (i === c) continue;
			const f = a[i * 4 + c];
			for (let k = 0; k < 4; k++) { a[i * 4 + k] -= f * a[c * 4 + k]; r[i * 4 + k] -= f * r[c * 4 + k]; }
		}
	}
	return r;
}
// Rows of the rotation about x, then y, then z (radians).
function __eulerRows(x, y, z) {
	const [sx, cx, sy, cy, sz, cz] = [Math.sin(x), Math.cos(x), Math.sin(y), Math.cos(y), Math.sin(z), Math.cos(z)];
	return [
		cy * cz, cy * sz, -sy,
		sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy,
		cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy,
	];
}
// The angles (radians) of a matrix's rotation, x then y then z.
function __eulerOf(m) {
	const z = Math.atan2(m[1], m[0]);
	const y = Math.atan2(-m[2], Math.sqrt(m[6] * m[6] + m[10] * m[10]));
	const x = Math.atan2(Math.sin(z) * m[8] - Math.cos(z) * m[9], Math.cos(z) * m[5] - Math.sin(z) * m[4]);
	return new Vec3(x, y, z);
}
const __IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
const __DEG = Math.PI / 180;

class Mat4 {
	constructor(arg) {
		if (arg instanceof Mat4) this.m = arg.m.slice();
		else if (Array.isArray(arg) && arg.length === 16) this.m = arg.map((v) => __num(v, 0));
		else if (typeof arg === 'string' && arg.trim().split(/\s+/).length === 16) this.m = arg.trim().split(/\s+/).map(Number);
		else this.m = __IDENTITY.slice();
	}
	static identity() { return new Mat4(); }
	static fromTranslation(v) { v = __vec3(v); const r = new Mat4(); r.m[12] = v.x; r.m[13] = v.y; r.m[14] = v.z; return r; }
	static fromScale(v) { v = __vec3(v); const r = new Mat4(); r.m[0] = v.x; r.m[5] = v.y; r.m[10] = v.z; return r; }
	static fromRotation(angle, axis) {
		const a = (axis ? __vec3(axis) : new Vec3(0, 0, 1)).normalize();
		const t = __num(angle, 0) * __DEG, c = Math.cos(t), s = Math.sin(t), k = 1 - c;
		return new Mat4([
			c + a.x * a.x * k, a.x * a.y * k + a.z * s, a.x * a.z * k - a.y * s, 0,
			a.x * a.y * k - a.z * s, c + a.y * a.y * k, a.y * a.z * k + a.x * s, 0,
			a.x * a.z * k + a.y * s, a.y * a.z * k - a.x * s, c + a.z * a.z * k, 0,
			0, 0, 0, 1,
		]);
	}
	static fromEuler(x, y, z) {
		if (x instanceof Vec3) ({ x, y, z } = x);
		const r = __eulerRows(__num(x, 0) * __DEG, __num(y, 0) * __DEG, __num(z, 0) * __DEG);
		return new Mat4([r[0], r[1], r[2], 0, r[3], r[4], r[5], 0, r[6], r[7], r[8], 0, 0, 0, 0, 1]);
	}
	translation(v) {
		if (v === undefined) return new Vec3(this.m[12], this.m[13], this.m[14]);
		v = __vec3(v);
		this.m[12] = v.x; this.m[13] = v.y; this.m[14] = v.z;
		return this;
	}
	right() { return new Vec3(this.m[0], this.m[1], this.m[2]); }
	up() { return new Vec3(this.m[4], this.m[5], this.m[6]); }
	forward() { return new Vec3(this.m[8], this.m[9], this.m[10]); }
	add(f) { return new Mat4(this.m.map((v, i) => v + f.m[i])); }
	subtract(f) { return new Mat4(this.m.map((v, i) => v - f.m[i])); }
	multiply(f) { return f instanceof Mat4 ? new Mat4(__mul4(this.m, f.m)) : new Mat4(this.m.map((v) => v * __num(f, 1))); }
	translate(v) { return this.multiply(Mat4.fromTranslation(v)); }
	rotate(angle, axis) { return this.multiply(Mat4.fromRotation(angle, axis)); }
	scale(v) { return this.multiply(Mat4.fromScale(v)); }
	transformPoint(v) {
		const m = this.m;
		return new Vec3(v.x * m[0] + v.y * m[4] + v.z * m[8] + m[12], v.x * m[1] + v.y * m[5] + v.z * m[9] + m[13], v.x * m[2] + v.y * m[6] + v.z * m[10] + m[14]);
	}
	transformDirection(v) {
		const m = this.m;
		return new Vec3(v.x * m[0] + v.y * m[4] + v.z * m[8], v.x * m[1] + v.y * m[5] + v.z * m[9], v.x * m[2] + v.y * m[6] + v.z * m[10]);
	}
	transpose() { const m = this.m; return new Mat4([0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15].map((i) => m[i])); }
	inverse() { return new Mat4(__inv4(this.m)); }
	determinant() {
		const m = this.m;
		const d3 = (a, b, c, d, e, f, g, h, i) => a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
		return m[0] * d3(m[5], m[6], m[7], m[9], m[10], m[11], m[13], m[14], m[15])
			- m[1] * d3(m[4], m[6], m[7], m[8], m[10], m[11], m[12], m[14], m[15])
			+ m[2] * d3(m[4], m[5], m[7], m[8], m[9], m[11], m[12], m[13], m[15])
			- m[3] * d3(m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14]);
	}
	extractEuler() { const e = __eulerOf(this.m); return new Vec3(e.x / __DEG, e.y / __DEG, e.z / __DEG); }
	copy() { return new Mat4(this); }
	equals(f) { return f instanceof Mat4 && this.m.every((v, i) => Math.abs(v - f.m[i]) < 1e-6); }
	toString() { return this.m.join(' '); }
}

globalThis.Vec2 = Vec2;
globalThis.Vec3 = Vec3;
globalThis.Vec4 = Vec4;
globalThis.Mat4 = Mat4;

// Scene values arrive as strings ("1 2 3"); scripts see vectors for the vector fields.
const __vecFields = { origin: 3, scale: 3, angles: 3, color: 3, parallaxDepth: 2 };
function __toScript(field, v) {
	const last = field.split('.').pop();
	const n = __vecFields[last] || (/^color/.test(last) ? 3 : 0);
	if (n && typeof v === 'string') return n === 2 ? Vec2.fromString(v) : Vec3.fromString(v);
	return v;
}
function __fromScript(v) {
	if (v instanceof Vec2 || v instanceof Vec3 || v instanceof Vec4 || v instanceof Mat4) return v.toString();
	if (Array.isArray(v)) return v.join(' ');
	return v;
}

// --- user properties declared by a script -------------------------------------------------

let __overrides = {};
function __override(name, fallback) {
	if (!Object.prototype.hasOwnProperty.call(__overrides, name)) return fallback;
	const v = __overrides[name];
	return v !== null && typeof v === 'object' && 'value' in v ? v.value : v;
}

class ScriptProperties {
	constructor() { this.__defs = []; }
	__add(def, value) { this.__defs.push(def); this[def.name] = __override(def.name, value); return this; }
	addCheckbox(d) { return this.__add(d, !!d.value); }
	addSlider(d) { return this.__add(d, __num(d.value, 0)); }
	addCombo(d) { return this.__add(d, d.value !== undefined ? d.value : (d.options && d.options.length ? d.options[0].value : '')); }
	addText(d) { return this.__add(d, d.value === undefined ? '' : String(d.value)); }
	addTextInput(d) { return this.addText(d); }
	addColor(d) { return this.__add(d, d.value instanceof Vec3 ? d.value : Vec3.fromString(d.value || '1 1 1')); }
	addFile(d) { return this.__add(d, d.value || ''); }
	addDirectory(d) { return this.__add(d, d.value || ''); }
	finish() {
		const out = {};
		for (const d of this.__defs) {
			let v = this[d.name];
			if (d.integer && typeof v === 'number') v = Math.round(v);
			if (d.name && /^color/i.test(d.name) && typeof v === 'string') v = Vec3.fromString(v);
			out[d.name] = v;
		}
		return out;
	}
}
globalThis.createScriptProperties = () => new ScriptProperties();

// --- layers -------------------------------------------------------------------------------

const __layers = new Map();   // id -> Layer
let __order = [];             // ids in draw order
const __sounds = [];          // sound objects: layers for scripts, never drawn or sorted
const __dirty = new Map();    // id -> {field: value}
const __created = [];         // {id, path, workshop}
const __moves = [];           // {id, index}
let __nextId = 1 << 30;

function __mark(layer, field, value) {
	let d = __dirty.get(layer.id);
	if (!d) { d = {}; __dirty.set(layer.id, d); }
	d[field] = __fromScript(value);
}

// Stands in for an animation or texture-sheet handle the renderer does not drive yet.
function __noopAnimation() {
	let frame = 0;
	return {
		play() {}, pause() {}, stop() {}, isPlaying() { return false; },
		getFrame() { return frame; }, setFrame(f) { frame = Math.trunc(__num(f, 0)); },
	};
}

// IAnimation: a keyframed value of a layer, by the name given in the editor. Commands queue up
// within a frame (`stop(); play();` restarts) and reach the renderer with the frame's changes.
const __animationQueue = new Map(); // `${layer id}|${name}` -> commands
class Animation {
	constructor(layer, a) { this._layer = layer; this._a = a; }
	get name() { return this._a.name; }
	get fps() { return this._a.fps; }
	get frameCount() { return this._a.frameCount; }
	get duration() { return this._a.frameCount / this._a.fps; }
	get rate() { return __num(this._a.rate, 1); }
	set rate(v) { this._a.rate = __num(v, 1); this.__send(`rate:${this._a.rate}`); }
	play() { this._a.playing = true; this.__send('play'); }
	pause() { this._a.playing = false; this.__send('pause'); }
	stop() { this._a.playing = false; this._a.frame = 0; this.__send('stop'); }
	isPlaying() { return !!this._a.playing; }
	getFrame() { return __num(this._a.frame, 0); }
	setFrame(f) { this._a.frame = __num(f, 0); this.__send(`frame:${this._a.frame}`); }
	__send(command) {
		const key = `${this._layer.id}|${this._a.name}`;
		const queue = __animationQueue.get(key) || [];
		queue.push(command);
		__animationQueue.set(key, queue);
		__mark(this._layer, `animation:${this._a.name}`, queue.join(';'));
	}
}

class Layer {
	constructor(s) { this._s = s; }
	get id() { return this._s.id; }
	get name() { return this._s.name; }
	get debug() { return false; }
	get size() { return Vec2.fromString(this._s.size || '0 0'); }
	get origin() { return Vec3.fromString(this._s.origin); }
	set origin(v) { this._s.origin = __fromScript(__vec3(v)); __mark(this, 'origin', this._s.origin); }
	get scale() { return Vec3.fromString(this._s.scale); }
	set scale(v) { this._s.scale = __fromScript(__vec3(v)); __mark(this, 'scale', this._s.scale); }
	get angles() { return Vec3.fromString(this._s.angles); }
	set angles(v) { this._s.angles = __fromScript(__vec3(v)); __mark(this, 'angles', this._s.angles); }
	get color() { return Vec3.fromString(this._s.color); }
	set color(v) { this._s.color = __fromScript(__vec3(v)); __mark(this, 'color', this._s.color); }
	get alpha() { return __num(this._s.alpha, 1); }
	set alpha(v) { this._s.alpha = __num(v, 1); __mark(this, 'alpha', this._s.alpha); }
	get visible() { return !!this._s.visible; }
	set visible(v) { this._s.visible = !!v; __mark(this, 'visible', this._s.visible); }
	get text() { return this._s.text || ''; }
	set text(v) { this._s.text = String(v); __mark(this, 'text', this._s.text); }
	get parallaxDepth() { return Vec2.fromString(this._s.parallaxDepth || '0 0'); }
	set parallaxDepth(v) { this._s.parallaxDepth = __fromScript(__vec2(v)); __mark(this, 'parallaxDepth', this._s.parallaxDepth); }
	// Which point of an image layer's box sits on its origin.
	get alignment() { return this._s.alignment || 'center'; }
	set alignment(v) { this._s.alignment = String(v); __mark(this, 'alignment', this._s.alignment); }
	getEffectCount() { return (this._s.effects || []).length; }
	getEffect(key) {
		const list = this._s.effects || [];
		const index = typeof key === 'number' ? key : list.findIndex((e) => e.name === key);
		return index >= 0 && index < list.length ? new Effect(this, index, list[index]) : null;
	}
	getParent() { return this._s.parent === undefined || this._s.parent === null ? null : (__layers.get(this._s.parent) || null); }
	// A keyframed value's animation by its editor name; a name the layer does not have gets a
	// stand-in, so scripts that ask for it keep running.
	getAnimation(name) {
		const a = (this._s.animations || []).find((x) => x.name === name);
		if (!a) return __noopAnimation();
		this.__animations = this.__animations || new Map();
		if (!this.__animations.has(name)) this.__animations.set(name, new Animation(this, a));
		return this.__animations.get(name);
	}
	// Texture sheet playback is not driven from scripts.
	getTextureAnimation() { return __noopAnimation(); }
	getVideoTexture() { return null; }
	// ISoundLayer: a sound object plays, pauses and stops; other layers ignore these.
	play() { this.__sound('play', true); }
	pause() { this.__sound('pause', false); }
	stop() { this.__sound('stop', false); }
	isPlaying() { return this._s.sound ? !!this._s.playing : true; }
	get volume() { return __num(this._s.volume, 1); }
	set volume(v) { this._s.volume = Math.min(Math.max(__num(v, 1), 0), 1); __mark(this, 'volume', this._s.volume); }
	__sound(command, playing) {
		if (!this._s.sound) return;
		this._s.playing = playing;
		__mark(this, 'sound', command);
	}
}

// Puppet calls of a layer, as Wallpaper Engine runs them: puppets are posed before scripts run,
// so the getters read this frame's pose, and every bone or morph target setter overrides this
// frame only (scripts set them again each frame). Bones are found by index or by exact name.
const __puppets = new Map();      // layer id -> this frame's pose (from the renderer)
const __puppetCalls = new Map();  // layer id -> calls of this frame
const __animLayers = new Map();   // uid -> AnimationLayer
let __nextAnimUid = 1 << 20;

function __puppetCall(layer, call) {
	const list = __puppetCalls.get(layer.id) || [];
	list.push(call);
	__puppetCalls.set(layer.id, list);
	__mark(layer, 'puppet', JSON.stringify(list));
}

function __pose(layer) {
	let p = __puppets.get(layer.id);
	if (!p && layer._s.puppet) {
		p = { stub: true, world: __IDENTITY.slice(), model: [], weights: [], layers: [], ended: [] };
		__puppets.set(layer.id, p);
	}
	return p;
}

Object.assign(Layer.prototype, {
	__bones() { return (this._s.puppet && this._s.puppet.bones) || []; },
	__bone(b) {
		const bones = this.__bones(), p = __puppets.get(this.id);
		if (!p || p.stub) return -1;
		if (typeof b === 'number') return b >= 0 && b < bones.length ? Math.trunc(b) : -1;
		return typeof b === 'string' && b ? bones.findIndex((x) => x.name === b) : -1;
	},
	__model(i) { return __puppets.get(this.id).model.slice(i * 16, i * 16 + 16); },
	__setModel(i, m) {
		const p = __puppets.get(this.id);
		for (let k = 0; k < 16; k++) p.model[i * 16 + k] = m[k];
		__puppetCall(this, { op: 'bone', i, model: m });
	},
	// Local matrices (parent space), taken from this frame's pose the first time they are needed.
	__locals() {
		const p = __puppets.get(this.id);
		if (!p.local) {
			const bones = this.__bones();
			p.local = bones.map((b, i) => (b.parent < 0 ? this.__model(i) : __mul4(this.__model(i), __inv4(this.__model(b.parent)))));
		}
		return p.local;
	},
	// A local matrix changed: the bone and every bone below it follow.
	__propagate(i) {
		const bones = this.__bones(), local = this.__locals(), moved = new Set([i]);
		for (let j = i; j < bones.length; j++) {
			if (j !== i && !moved.has(bones[j].parent)) continue;
			const parent = bones[j].parent;
			this.__setModel(j, parent < 0 ? local[j].slice() : __mul4(local[j], this.__model(parent)));
			moved.add(j);
		}
	},
	getBoneCount() { return this.__bones().length; },
	getBoneIndex(name) { return typeof name === 'string' && name ? this.__bones().findIndex((b) => b.name === name) : -1; },
	getBoneParentIndex(b) { const i = this.__bone(b); return i < 0 ? -1 : this.__bones()[i].parent; },
	getBoneTransform(b) {
		const i = this.__bone(b);
		return i < 0 ? new Mat4() : new Mat4(__mul4(this.__model(i), __puppets.get(this.id).world));
	},
	setBoneTransform(b, m) {
		const i = this.__bone(b);
		if (i >= 0 && m instanceof Mat4) this.__setModel(i, __mul4(m.m, __inv4(__puppets.get(this.id).world)));
	},
	getLocalBoneTransform(b) { const i = this.__bone(b); return i < 0 ? new Mat4() : new Mat4(this.__locals()[i]); },
	setLocalBoneTransform(b, m) {
		const i = this.__bone(b);
		if (i < 0 || !(m instanceof Mat4)) return;
		this.__locals()[i] = m.m.slice();
		this.__propagate(i);
	},
	// Radians, unlike most script angles.
	getLocalBoneAngles(b) { const i = this.__bone(b); return i < 0 ? new Vec3(0, 0, 0) : __eulerOf(this.__locals()[i]); },
	setLocalBoneAngles(b, v) {
		const i = this.__bone(b);
		if (i < 0) return;
		v = __vec3(v);
		const r = __eulerRows(v.x, v.y, v.z), l = this.__locals()[i];
		// The rotation replaces the matrix's axes, scale included; the translation stays.
		for (let row = 0; row < 3; row++) {
			for (let c = 0; c < 3; c++) l[row * 4 + c] = r[row * 3 + c];
			l[row * 4 + 3] = 0;
		}
		this.__propagate(i);
	},
	getLocalBoneOrigin(b) { const i = this.__bone(b); if (i < 0) return new Vec3(0, 0, 0); const l = this.__locals()[i]; return new Vec3(l[12], l[13], l[14]); },
	setLocalBoneOrigin(b, v) {
		const i = this.__bone(b);
		if (i < 0) return;
		v = __vec3(v);
		const l = this.__locals()[i];
		l[12] = v.x; l[13] = v.y; l[14] = v.z;
		this.__propagate(i);
	},
	// `translation` in scene units, `angles` in degrees; the push acts in the next physics step.
	applyBonePhysicsImpulse(b, translation, angles) {
		const i = b === '' ? 0 : this.__bone(b);
		if (i < 0) return;
		const t = __vec3(translation || 0), r = __vec3(angles || 0);
		__puppetCall(this, { op: 'impulse', i, t: [t.x, t.y, t.z], r: [r.x, r.y, r.z] });
	},
	resetBonePhysicsSimulation(b) { const i = this.__bone(b); if (i >= 0) __puppetCall(this, { op: 'reset', i }); },
	__shapes() { return (this._s.puppet && this._s.puppet.shapes) || []; },
	__shape(b) { return typeof b === 'number' ? Math.trunc(b) : this.__shapes().indexOf(b); },
	getBlendShapeIndex(name) { return this.__shapes().indexOf(name); },
	getBlendShapeWeight(b) { const p = __pose(this), i = this.__shape(b); return (p && p.weights[i]) || 0; },
	// Replaces what the animations gave the target this frame.
	setBlendShapeWeight(b, w) {
		const p = __pose(this), i = this.__shape(b);
		if (!p || i < 0 || i >= this.__shapes().length) return;
		p.weights[i] = __num(w, 0);
		__puppetCall(this, { op: 'shape', i, w: p.weights[i] });
	},
	getAnimationLayerCount() { const p = __pose(this); return p ? p.layers.length : 0; },
	getAnimationLayer(key) {
		const p = __pose(this);
		if (!p) return null;
		let s = null;
		if (typeof key === 'number') s = p.layers[Math.trunc(key)] || null;
		else for (const l of p.layers) if (l.name === key) s = l;  // the last match
		return s ? __animLayer(this, s.uid) : null;
	},
	createAnimationLayer(animation, options) { return __createAnimLayer(this, animation, options, false); },
	// Like createAnimationLayer; the layer goes once it ends (wraps, turns or finishes).
	playSingleAnimation(animation, options) { return __createAnimLayer(this, animation, options, true); },
	destroyAnimationLayer(key) {
		const p = __pose(this);
		if (!p) return false;
		const gone = key instanceof AnimationLayer ? p.layers.filter((l) => l.uid === key._uid)
			: typeof key === 'number' ? [p.layers[Math.trunc(key)]].filter(Boolean)
			: p.layers.filter((l) => l.name === key);
		for (const l of gone) {
			p.layers.splice(p.layers.indexOf(l), 1);
			__puppetCall(this, { op: 'destroy', uid: l.uid });
		}
		return gone.length > 0;
	},
});

function __createAnimLayer(layer, animation, options, once) {
	const p = __pose(layer);
	const list = (layer._s.puppet && layer._s.puppet.animations) || [];
	if (!p || animation === undefined || animation === null || animation === '') return null;
	let opts = options;
	if (typeof opts === 'string') { try { opts = JSON.parse(opts); } catch (e) { opts = {}; } }
	opts = { ...(opts || {}) };
	if (!opts.blendin) opts.blendin = true;
	if (!opts.blendout) opts.blendout = true;
	let cfg;
	if (typeof animation === 'string') {
		const a = list.find((x) => x.name === animation);
		if (!a) return null;
		cfg = { ...opts, animation: a.id };
	} else {
		cfg = { ...animation, ...opts };
	}
	const a = list.find((x) => x.id === cfg.animation);
	if (typeof cfg.animation !== 'number' || !a) return null;
	cfg.once = once;
	const uid = __nextAnimUid++;
	const s = {
		uid, name: String(cfg.name || ''), animation: a.id, rate: __num(cfg.rate, 1), blend: __num(cfg.blend, 1),
		visible: cfg.visible === undefined ? true : !!cfg.visible, additive: !!cfg.additive, blendin: true,
		blendout: a.mode === 'single', blendtime: __num(cfg.blendtime, 0.5), fps: a.fps, frameCount: a.frames,
		duration: a.fps > 0 ? a.frames / a.fps : 0, frame: 0, playing: true,
	};
	const n = p.layers.length;
	let at = n;
	if (cfg.autosort === true) { at = n; while (at > 0 && p.layers[at - 1].additive) at--; }
	else if (typeof cfg.index === 'number') at = Math.min(Math.max(0, Math.trunc(cfg.index)), Math.max(n - 1, 0));
	p.layers.splice(at, 0, s);
	__puppetCall(layer, { op: 'create', uid, cfg });
	return __animLayer(layer, uid);
}

function __animLayer(layer, uid) {
	let a = __animLayers.get(uid);
	if (!a) { a = new AnimationLayer(layer, uid); __animLayers.set(uid, a); }
	return a;
}

// IAnimationLayer: one of a puppet's animation layers. Changes reach the renderer with the frame
// and apply from the next one.
class AnimationLayer {
	constructor(layer, uid) { this._layer = layer; this._uid = uid; this._ended = []; }
	get _s() {
		const p = __puppets.get(this._layer.id);
		return (p && p.layers.find((l) => l.uid === this._uid)) || { uid: this._uid };
	}
	__set(field, v) { this._s[field] = v; __puppetCall(this._layer, { op: 'layer', uid: this._uid, set: { [field]: v } }); }
	__call(call, f) { __puppetCall(this._layer, { op: 'layer', uid: this._uid, call, f }); }
	get name() { return this._s.name || ''; }
	set name(v) { this.__set('name', String(v)); }
	get rate() { return __num(this._s.rate, 1); }
	set rate(v) { this.__set('rate', __num(v, 1)); }
	get blend() { return __num(this._s.blend, 1); }
	set blend(v) { this.__set('blend', __num(v, 1)); }
	get blendtime() { return __num(this._s.blendtime, 0.5); }
	set blendtime(v) { this.__set('blendtime', __num(v, 0.5)); }
	get visible() { return this._s.visible !== false; }
	set visible(v) { this.__set('visible', !!v); }
	get additive() { return !!this._s.additive; }
	set additive(v) { this.__set('additive', !!v); }
	get blendin() { return !!this._s.blendin; }
	set blendin(v) { this.__set('blendin', !!v); }
	get blendout() { return !!this._s.blendout; }
	set blendout(v) { this.__set('blendout', !!v); }
	get fps() { return __num(this._s.fps, 0); }
	get frameCount() { return __num(this._s.frameCount, 0); }
	get duration() { return __num(this._s.duration, 0); }
	play() { this._s.playing = true; this.__call('play'); }
	pause() { this._s.playing = false; this.__call('pause'); }
	stop() { this._s.playing = false; this._s.frame = 0; this.__call('stop'); }
	isPlaying() { return !!this._s.playing; }
	getFrame() { return __num(this._s.frame, 0); }
	setFrame(f) { this._s.frame = __num(f, 0); this.__call('frame', this._s.frame); }
	addEndedCallback(fn) { if (typeof fn === 'function') this._ended.push(fn); }
}
globalThis.AnimationLayer = AnimationLayer;

// IEffect: one material effect on a layer. `visible` is applied by the renderer each frame.
class Effect {
	constructor(layer, index, s) { this._layer = layer; this._index = index; this._s = s; }
	get name() { return this._s.name || ''; }
	get visible() { return this._s.visible !== false; }
	set visible(v) { this._s.visible = !!v; __mark(this._layer, `effect:${this._index}:visible`, this._s.visible); }
	getMaterialCount() { return (this._s.passes || []).length; }
	// IMaterial: one pass's shader constants by name; each write goes to the renderer.
	getMaterial(pass) {
		const layer = this._layer, index = this._index;
		const values = { ...((this._s.passes || [])[pass] || {}) };
		return new Proxy(values, {
			set(target, key, v) {
				target[key] = v;
				__mark(layer, `effects[${index}].passes[${pass}].constantshadervalues.${String(key)}`, v);
				return true;
			},
		});
	}
}

// ITextLayer and IImageLayer fields from the WE docs. Each write is sent to the renderer, which
// applies the ones it supports; the rest are stored so scripts that set them keep running.
const __layerFields = {
	pointsize: 0, font: '', padding: 0, horizontalalign: 'center', verticalalign: 'center',
	opaquebackground: false, backgroundcolor: '0 0 0', limitwidth: false, maxwidth: 0,
	limitrows: false, maxrows: 0, anchor: 'none', perspective: false, solid: false,
};
for (const [field, fallback] of Object.entries(__layerFields)) {
	Object.defineProperty(Layer.prototype, field, {
		get() { return this._s[field] === undefined ? fallback : this._s[field]; },
		set(v) { this._s[field] = v; __mark(this, field, v); },
	});
}

// IScene properties from the WE docs. The renderer does not read these yet; they are kept on the
// scene so scripts that set them keep running.
const __sceneFields = {
	bloom: false, bloomstrength: 2, bloomthreshold: 0.65, clearenabled: true, clearcolor: '0 0 0',
	ambientcolor: '0.3 0.3 0.3', skylightcolor: '0.3 0.3 0.3', fov: 50, nearz: 0.01, farz: 10000,
	camerafade: true, camerashake: false, camerashakespeed: 3, camerashakeamplitude: 0.5,
	camerashakeroughness: 1, cameraparallax: false, cameraparallaxamount: 0.5,
	cameraparallaxdelay: 0.1, cameraparallaxmouseinfluence: 0.5,
};
const __sceneValues = { ...__sceneFields };
const __sceneDirty = {};       // scene fields written since the last flush

const thisScene = {
	getLayer(key) {
		if (typeof key === 'number') return __layers.get(__order[key]) || null;
		for (const id of __order) { const l = __layers.get(id); if (l && l.name === key) return l; }
		return __sounds.find((l) => l.name === key) || null;
	},
	getLayerIndex(layer) {
		const l = typeof layer === 'string' ? this.getLayer(layer) : layer;
		return l ? __order.indexOf(l.id) : -1;
	},
	getLayerCount() { return __order.length; },
	enumerateLayers() { return __order.map((id) => __layers.get(id)).filter(Boolean); },
	createLayer(src) {
		// A path, an asset from engine.registerAsset, or a layer description ({image, origin, ...}).
		const path = typeof src === 'string' ? src : (src && (src.image || src.particle || src.path)) || '';
		const id = __nextId++;
		const base = typeof src === 'object' && src ? src : {};
		const s = {
			id, name: base.name || path, origin: __fromScript(base.origin || '0 0 0'), scale: __fromScript(base.scale || '1 1 1'),
			angles: __fromScript(base.angles || '0 0 0'), color: '1 1 1', alpha: 1, visible: true, text: '', size: '0 0',
		};
		const layer = new Layer(s);
		__layers.set(id, layer);
		__order.push(id);
		__created.push({ id, path, workshop: __currentWorkshop });
		return layer;
	},
	destroyLayer(layer) {
		if (!layer) return;
		layer.visible = false;
	},
	sortLayer(layer, index) {
		if (!layer) return;
		const from = __order.indexOf(layer.id);
		if (from < 0) return;
		__order.splice(from, 1);
		const to = Math.max(0, Math.min(__order.length, Math.trunc(__num(index, __order.length))));
		__order.splice(to, 0, layer.id);
		__moves.push({ id: layer.id, index: to });
	},
	getCameraTransforms() { return { eye: new Vec3(0, 0, 0), center: new Vec3(0, 0, -1), up: new Vec3(0, 1, 0) }; },
	clearColor: new Vec3(0, 0, 0),
	bloom: false,
};
for (const field of Object.keys(__sceneFields)) {
	Object.defineProperty(thisScene, field, {
		get() { return __sceneValues[field]; },
		set(v) { __sceneValues[field] = v; __sceneDirty[field] = __fromScript(v); },
	});
}
globalThis.thisScene = thisScene;
globalThis.thisLayer = null;
// The object a script belongs to: its effect for a script on an effect value, else its layer.
globalThis.thisObject = null;

// --- engine, input, audio -----------------------------------------------------------------

const __audio = [];
const engine = {
	frametime: 0,
	runtime: 0,
	timeOfDay: 0,
	screenResolution: new Vec2(1920, 1080),
	canvasSize: new Vec2(1920, 1080),
	userProperties: {},
	AUDIO_RESOLUTION_16: 16,
	AUDIO_RESOLUTION_32: 32,
	AUDIO_RESOLUTION_64: 64,
	registerAudioBuffers(resolution) {
		const n = [16, 32, 64].includes(resolution) ? resolution : 16;
		const b = { resolution: n, left: new Float32Array(n), right: new Float32Array(n), average: new Float32Array(n) };
		__audio.push(b);
		return b;
	},
	isDesktopDevice() { return true; },
	isMobileDevice() { return false; },
	isWallpaper() { return true; },
	isScreensaver() { return false; },
	isRunningInEditor() { return false; },
	isPortrait() { return this.screenResolution.y > this.screenResolution.x; },
	isLandscape() { return !this.isPortrait(); },
	openUserShortcut() {},
	// An image model, particle system or other file a script places with thisScene.createLayer.
	registerAsset(path) { return { path: String(path) }; },
	setTimeout(fn, ms) { return __addTimer(fn, __num(ms, 0) / 1000, 0); },
	setInterval(fn, ms) { const every = Math.max(__num(ms, 0) / 1000, 0.001); return __addTimer(fn, every, every); },
	clearTimeout(id) { __clearTimer(id); },
	clearInterval(id) { __clearTimer(id); },
};
const __timers = [];
let __nextTimer = 1;
function __addTimer(fn, delay, every) {
	const id = __nextTimer++;
	__timers.push({ id, at: engine.runtime + delay, fn, every });
	return id;
}
function __clearTimer(id) {
	const i = __timers.findIndex((t) => t.id === id);
	if (i >= 0) __timers.splice(i, 1);
}
globalThis.setTimeout = engine.setTimeout;
globalThis.setInterval = engine.setInterval;
globalThis.clearTimeout = engine.clearTimeout;
globalThis.clearInterval = engine.clearInterval;
globalThis.engine = engine;

const input = {
	cursorWorldPosition: new Vec3(0, 0, 0),
	cursorScreenPosition: new Vec2(0, 0),
	cursorLeftDown: false,
};
globalThis.input = input;

globalThis.shared = {};

// Kept between runs: the host restores it with __wm_storage and receives it whenever it changed.
// The location argument (global or per screen) is accepted; there is one store per scene.
const __store = new Map();
let __storeChanged = false;
globalThis.localStorage = {
	get(k) { return __store.has(k) ? __store.get(k) : undefined; },
	set(k, v) { __store.set(k, v); __storeChanged = true; },
	delete(k) { __storeChanged = __store.delete(k) || __storeChanged; },
	clear() { __storeChanged = __storeChanged || __store.size > 0; __store.clear(); },
	LOCATION_GLOBAL: 0,
	LOCATION_SCREEN: 1,
};

globalThis.console = {
	log(...a) { __wm_log(a.map(String).join(' ')); },
	info(...a) { __wm_log(a.map(String).join(' ')); },
	warn(...a) { __wm_log(a.map(String).join(' ')); },
	error(...a) { __wm_log(a.map(String).join(' ')); },
};

// Helper modules some scripts import by name.
globalThis.__WEMath = {
	PI: Math.PI,
	deg2rad: Math.PI / 180,
	rad2deg: 180 / Math.PI,
	clamp: (v, a, b) => Math.min(Math.max(v, a), b),
	mix: (a, b, t) => a + (b - a) * t,
	lerp: (a, b, t) => a + (b - a) * t,
	smoothStep: (a, b, v) => { const t = Math.min(Math.max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t); },
	fract: (v) => v - Math.floor(v),
};
globalThis.__WEVector = {
	Vec2, Vec3, Vec4,
	// Direction for an angle in degrees: x = cos, y = sin.
	angleVector2: (angle) => { const r = __num(angle, 0) * Math.PI / 180; return new Vec2(Math.cos(r), Math.sin(r)); },
	// Angle in degrees of a direction, counter-clockwise from +x.
	vectorAngle2: (direction) => { const d = __vec2(direction); return Math.atan2(d.y, d.x) * 180 / Math.PI; },
};
globalThis.__WEColor = {
	rgb2hsv(c) {
		c = __vec3(c);
		const max = Math.max(c.x, c.y, c.z), min = Math.min(c.x, c.y, c.z), d = max - min;
		let h = 0;
		if (d > 0) {
			if (max === c.x) h = ((c.y - c.z) / d) % 6;
			else if (max === c.y) h = (c.z - c.x) / d + 2;
			else h = (c.x - c.y) / d + 4;
			h /= 6; if (h < 0) h += 1;
		}
		return new Vec3(h, max > 0 ? d / max : 0, max);
	},
	hsv2rgb(c) {
		c = __vec3(c);
		const h = (c.x % 1 + 1) % 1 * 6, s = c.y, v = c.z, i = Math.floor(h), f = h - i;
		const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
		return [new Vec3(v, t, p), new Vec3(q, v, p), new Vec3(p, v, t), new Vec3(p, q, v), new Vec3(t, p, v), new Vec3(v, p, q)][i % 6];
	},
	normalizeColor(c) { c = __vec3(c); return new Vec3(c.x / 255, c.y / 255, c.z / 255); },
	expandColor(c) { c = __vec3(c); return new Vec3(c.x * 255, c.y * 255, c.z * 255); },
};

// --- host interface -----------------------------------------------------------------------

const __scripts = [];
let __currentWorkshop = '';

// Replaces the layer table, e.g. after a property change rebuilt the scene.
globalThis.__wm_layers = function (json) {
	const list = JSON.parse(json);
	__order = list.filter((s) => !s.sound).map((s) => s.id);
	for (const s of list) {
		const l = __layers.get(s.id);
		if (l) Object.assign(l._s, s);
		else {
			const layer = new Layer(s);
			__layers.set(s.id, layer);
			if (s.sound) __sounds.push(layer);
		}
	}
	return '';
};

// User properties: `all` replaces engine.userProperties; `changed` (all of them on the first
// call) goes to every script's applyUserProperties. Colours arrive as vectors.
globalThis.__wm_user_properties = function (json) {
	const { values, colors } = JSON.parse(json);
	const changed = {};
	for (const [k, v] of Object.entries(values)) {
		changed[k] = colors.includes(k) && typeof v === 'string' ? Vec3.fromString(v) : v;
	}
	Object.assign(engine.userProperties, changed);
	for (const s of __scripts) __send(s, 'applyUserProperties', changed);
	return __takeEvents({ values: {} });
};

globalThis.__wm_storage = function (json) {
	for (const [k, v] of Object.entries(JSON.parse(json) || {})) __store.set(k, v);
	return '';
};

// Called before a script module is evaluated: its layer and its stored properties.
globalThis.__wm_begin = function (layerId, propsJson) {
	globalThis.thisLayer = __layers.get(layerId) || null;
	globalThis.thisObject = globalThis.thisLayer;
	__overrides = JSON.parse(propsJson) || {};
};

globalThis.__wm_register = function (id, ns, layerId, field, valueJson) {
	const layer = __layers.get(layerId) || null;
	const effect = /^effects\[(\d+)\]/.exec(field);
	const s = {
		id, ns, field, layer, failed: false,
		object: effect && layer ? layer.getEffect(Number(effect[1])) : layer,
		value: __toScript(field, JSON.parse(valueJson)),
	};
	__currentWorkshop = ns.__workshopId ? String(ns.__workshopId) : '';
	__enter(s);
	if (typeof ns.init === 'function') {
		try {
			const r = ns.init(s.value);
			if (r !== undefined) s.value = r;
		} catch (e) {
			s.failed = true;
			__wm_log(`script ${field}: init: ${e}`);
		}
	}
	__currentWorkshop = '';
	__scripts.push(s);
	return __takeEvents({ values: { [id]: __fromScript(s.value) } });
};

function __takeEvents(out) {
	out.dirty = {};
	for (const [id, d] of __dirty) out.dirty[id] = d;
	__dirty.clear();
	__animationQueue.clear();
	__puppetCalls.clear();
	out.scene = { ...__sceneDirty };
	for (const k of Object.keys(__sceneDirty)) delete __sceneDirty[k];
	out.created = __created.splice(0);
	out.moves = __moves.splice(0);
	if (__storeChanged) {
		out.storage = Object.fromEntries(__store);
		__storeChanged = false;
	}
	return JSON.stringify(out);
}

function __fill(buffer, src) {
	const n = buffer.length, m = src.length || 1;
	for (let i = 0; i < n; i++) {
		const a = Math.floor((i * m) / n), b = Math.max(a + 1, Math.floor(((i + 1) * m) / n));
		let sum = 0;
		for (let k = a; k < b; k++) sum += src[k] || 0;
		buffer[i] = sum / (b - a);
	}
}

// The layer's box in scene units: its origin and scale carried through its parents (rotation
// is ignored, which is enough to tell whether the pointer is over it).
// shortcut: camera parallax offsets are not included, so a click on a moved layer can miss by up
// to 3% of the scene; send each layer's offset in the frame input if a clickable scene needs it.
function __contains(layer, p) {
	let o = layer.origin, s = layer.scale;
	for (let q = layer.getParent(); q; q = q.getParent()) {
		const qs = q.scale, qo = q.origin;
		o = new Vec3(qo.x + o.x * qs.x, qo.y + o.y * qs.y, 0);
		s = new Vec3(s.x * qs.x, s.y * qs.y, 1);
	}
	const size = layer.size;
	return Math.abs(p.x - o.x) <= Math.abs(size.x * s.x) / 2 && Math.abs(p.y - o.y) <= Math.abs(size.y * s.y) / 2;
}

let __wasDown = false;
let __pressed = [];

// Runs as script `s`: its thisLayer and thisObject.
function __enter(s) {
	globalThis.thisLayer = s.layer;
	globalThis.thisObject = s.object;
}

function __send(s, name, event) {
	if (s.failed || typeof s.ns[name] !== 'function') return;
	__enter(s);
	try { s.ns[name](event); } catch (e) { __wm_log(`script ${s.field}: ${name}: ${e}`); }
}

// cursorDown/cursorUp/cursorClick go to scripts whose layer is under the pointer when the button
// is pressed; cursorMove goes to every script, so a drag keeps following the pointer.
function __cursorEvents(down) {
	const event = { worldPosition: input.cursorWorldPosition, screenPosition: input.cursorScreenPosition };
	input.cursorLeftDown = down;
	if (down && !__wasDown) {
		__pressed = __scripts.filter((s) => s.layer && s.layer.visible && __contains(s.layer, event.worldPosition));
		for (const s of __pressed) __send(s, 'cursorDown', event);
	}
	for (const s of __scripts) __send(s, 'cursorMove', event);
	if (!down && __wasDown) {
		for (const s of __pressed) {
			__send(s, 'cursorUp', event);
			if (__contains(s.layer, event.worldPosition)) __send(s, 'cursorClick', event);
		}
		__pressed = [];
	}
	__wasDown = down;
}

let __screen = null;

globalThis.__wm_frame = function (json) {
	const f = JSON.parse(json);
	engine.frametime = f.dt;
	engine.runtime = f.time;
	engine.timeOfDay = f.tod;
	engine.screenResolution = new Vec2(f.screen[0], f.screen[1]);
	for (const l of __sounds) l._s.playing = f.playing.includes(l.id);
	if (__screen && (__screen.x !== f.screen[0] || __screen.y !== f.screen[1])) {
		for (const s of __scripts) __send(s, 'resizeScreen', engine.screenResolution);
	}
	__screen = engine.screenResolution;
	engine.canvasSize = new Vec2(f.canvas[0], f.canvas[1]);
	input.cursorScreenPosition = new Vec2(f.cursor[0], f.cursor[1]);
	input.cursorWorldPosition = new Vec3(f.cursorWorld[0], f.cursorWorld[1], 0);
	// This frame's puppet poses; animation layers that ended call back first, as the puppet
	// update does before scripts run.
	__puppets.clear();
	for (const [id, pose] of Object.entries(f.puppets || {})) {
		__puppets.set(Number(id), pose);
		for (const uid of pose.ended) {
			const a = __animLayers.get(uid);
			if (!a) continue;
			for (const fn of a._ended) {
				try { fn(a); } catch (e) { __wm_log(`animation ended callback: ${e}`); }
			}
		}
	}
	__cursorEvents(!!f.down);
	for (const b of __audio) {
		__fill(b.left, f.left);
		__fill(b.right, f.right);
		for (let i = 0; i < b.resolution; i++) b.average[i] = (b.left[i] + b.right[i]) / 2;
	}
	for (let i = 0; i < __timers.length; i++) {
		const t = __timers[i];
		if (engine.runtime < t.at) continue;
		try { t.fn(); } catch (e) { __wm_log(`timer: ${e}`); }
		if (t.every > 0) t.at += t.every; else { __timers.splice(i, 1); i--; }
	}
	const values = {};
	for (const s of __scripts) {
		if (s.failed || typeof s.ns.update !== 'function') continue;
		__enter(s);
		try {
			const r = s.ns.update(s.value);
			if (r !== undefined) {
				s.value = r;
				values[s.id] = __fromScript(r);
			}
		} catch (e) {
			s.failed = true;
			__wm_log(`script ${s.field}: update: ${e}`);
		}
	}
	return __takeEvents({ values });
};

// A script that needs nothing per frame lets the renderer stop drawing a still scene.
globalThis.__wm_animated = function () {
	return __scripts.some((s) => !s.failed && typeof s.ns.update === 'function') || __timers.length > 0;
};
