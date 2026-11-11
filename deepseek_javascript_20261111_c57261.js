// ====== VIEW CONSTANTS ======
const SCREEN_WIDTH  = 1920;
const SCREEN_HEIGHT = 1080;
const WORLD_SCREENS_X = 5;
const WORLD_SCREENS_Y = 5;
const WORLD_WIDTH  = SCREEN_WIDTH  * WORLD_SCREENS_X;
const WORLD_HEIGHT = SCREEN_HEIGHT * WORLD_SCREENS_Y;

const VIEW_WIDTH  = SCREEN_WIDTH;
const VIEW_HEIGHT = SCREEN_HEIGHT;

// ====== PHYSICS CONSTANTS ======
const GRAVITY = 1.05;
const MAX_FALL_SPEED = 40;
const MOVE_SPEED = 9.5;
const JUMP_HEIGHT = 235;
const JUMP_VELOCITY = Math.sqrt(2 * GRAVITY * JUMP_HEIGHT);

const SLOPE_STATIC_ANGLE = 22;
const SLOPE_STEEP_ANGLE  = 60;
const SLOPE_SLIDE_ACCEL  = 2.5;
const SLOPE_EJECT_SPEED  = 4;
const SLOPE_MAX_SPEED    = 13;

// ====== LEVEL ======
const platforms = [];

const level = [
    {
        blocks: [
            { x: 0, y: WORLD_HEIGHT - 60, width: WORLD_WIDTH, height: 60, rotation: 0 },
            { x: 0, y: 5340, width: 9600, height: 60, rotation: 0 },
            { x: 290, y: 5180, width: 150, height: 40, rotation: 0 },
            { x: 670, y: 5100, width: 150, height: 40, rotation: 0 },
            { x: 1060, y: 5020, width: 150, height: 40, rotation: -19.3 },
            { x: 1351, y: 5061, width: 145, height: 42, rotation: 48.3 },
            { x: 1500, y: 4870, width: 568, height: 42, rotation: -73 },
        ]
    }
];

function buildLevel() {
    platforms.length = 0;

    for (const b of level[0].blocks) {
        platforms.push({
            x: b.x, y: b.y,
            width: b.width, height: b.height,
            rotation: b.rotation || 0
        });
    }
}

// ====== TICK ENGINE VARS ======
const tickLength = 20;
let frameAccumulator = 0;
let lastTimestamp = 0;

// ====== PLAYER CLASS ======
class Player {
    constructor(x, y) {
        this.x = x;
        this.y = y;
        this.width  = 80;
        this.height = 80;
        this.velX = 0;
        this.velY = 0;
        this.speed = MOVE_SPEED;

        this.onGround = false;
        this.facing   = 1;

        this.tilt        = 0;
        this.targetTilt  = 0;

        this.onSlope              = false;
        this.slopeCoyote          = 0;
        this.currentSlopeAngle    = 0;
        this.currentSlopeNormalX  = 0;
        this.currentSlopeNormalY  = -1;

        this.currentPlatform = null;
        this.tipVel = 0;
        this.isTipping = false;
    }

    update() {
        let dir = 0;
        if (keys.a && !keys.d) dir = -1;
        else if (keys.d && !keys.a) dir = 1;

        if (dir !== 0) {
            this.velX = dir * this.speed;
            this.facing = dir;
        } else {
            this.velX *= 0.85;
            if (Math.abs(this.velX) < 0.3) this.velX = 0;
        }

        if (keys.space && this.onGround) {
            this.velY = -JUMP_VELOCITY;
            this.onGround = false;
            this.onSlope  = false;
            this.slopeCoyote = 0;
            this.targetTilt = 0;
            this.isTipping = false;
            this.tipVel = 0;
        }

        this.velY = Math.min(this.velY + GRAVITY, MAX_FALL_SPEED);

        const slopeActive = this.onSlope || this.slopeCoyote > 0;

        if (slopeActive && this.currentSlopeAngle > SLOPE_STATIC_ANGLE) {
            const slideAng = (this.currentSlopeAngle - SLOPE_STATIC_ANGLE) * Math.PI / 180;
            const slopeSign = this.currentSlopeNormalX > 0 ? 1 : -1;
            const downX = -this.currentSlopeNormalY * slopeSign;
            const accel = GRAVITY * Math.sin(slideAng) * SLOPE_SLIDE_ACCEL;
            this.velX += downX * accel;
        }

        if (slopeActive) {
            const nx = this.currentSlopeNormalX;
            const ny = this.currentSlopeNormalY;
            const vDotN = this.velX * nx + this.velY * ny;
            this.velX -= vDotN * nx;
            this.velY -= vDotN * ny;
        }

        if (slopeActive) {
            const spd = Math.hypot(this.velX, this.velY);
            if (spd > SLOPE_MAX_SPEED) {
                this.velX *= SLOPE_MAX_SPEED / spd;
                this.velY *= SLOPE_MAX_SPEED / spd;
            }
        }

        this.x += this.velX;
        this.collide(0);

        this.onGround = false;
        this.onSlope  = false;
        this.currentPlatform = null;
        this.y += this.velY;
        this.collide(1);

        this.resolveRotatedCollisions();

        if (this.onSlope) {
            this.slopeCoyote = 3;
        } else if (this.slopeCoyote > 0) {
            this.slopeCoyote--;
        }

        let tdir = 0;
        if (this.onGround && this.currentPlatform) {
            const p = this.currentPlatform;
            const cx = this.x + this.width / 2;
            const cy = this.y + this.height;

            const bx = p.x + p.width / 2;
            const by = p.y + p.height / 2;
            const rad = p.rotation * Math.PI / 180;
            const cos = Math.cos(rad), sin = Math.sin(rad);
            const dx = cx - bx;
            const dy = cy - by;
            const localX = dx * cos + dy * sin;

            let overhang = 0;
            if (localX > p.width / 2) overhang = localX - p.width / 2;
            else if (localX < -p.width / 2) overhang = -p.width / 2 - localX;

            if (overhang > 0) {
                tdir = localX > 0 ? 1 : -1;
                this.tipVel += tdir * overhang * 0.005;
                this.tipVel = clamp(this.tipVel, -0.3, 0.3);
                this.isTipping = true;
            } else {
                this.tipVel = 0;
                this.isTipping = false;
            }

            if (this.isTipping) {
                this.tilt += this.tipVel;
                if (Math.abs(this.tilt) > 60) {
                    this.onGround = false;
                    this.onSlope = false;
                    this.isTipping = false;
                    this.velY = Math.max(this.velY, 2);
                    this.velX += tdir * 2;
                }
            } else {
                this.tilt += (this.targetTilt - this.tilt) * (this.onSlope ? 0.18 : 0.15);
            }
        } else {
            this.tipVel = 0;
            this.isTipping = false;
            this.tilt += (this.targetTilt - this.tilt) * 0.15;
        }

        this.x = clamp(this.x, 0, WORLD_WIDTH  - this.width);
        this.y = clamp(this.y, 0, WORLD_HEIGHT - this.height);
    }

    collide(axis) {
        for (const p of platforms) {
            if (p.rotation) continue;
            if (!isColliding(this, p)) continue;

            if (axis === 0) {
                if (this.velX > 0)      this.x = p.x - this.width;
                else if (this.velX < 0) this.x = p.x + p.width;
                this.velX = 0;
            } else {
                if (this.velY > 0) {
                    this.y = p.y - this.height;
                    this.onGround = true;
                    this.currentPlatform = p;
                } else if (this.velY < 0) {
                    this.y = p.y + p.height;
                }
                this.velY = 0;
            }
        }
    }

    resolveRotatedCollisions() {
        this.targetTilt = 0;

        for (const p of platforms) {
            if (!p.rotation) continue;
            
            const testBox = {
                x: this.x - 2,
                y: this.y - 2,
                width: this.width + 4,
                height: this.height + 4
            };
            
            const hit = satCollide(testBox, p);
            if (!hit) continue;

            const pushDepth = hit.depth - 2;
            if (pushDepth > 0) {
                this.x += hit.axis.x * pushDepth;
                this.y += hit.axis.y * pushDepth;
            }

            const nx = hit.axis.x;
            const ny = hit.axis.y;

            if (ny < -0.2) {
                const angleDeg = Math.acos(Math.min(1, -ny)) * 180 / Math.PI;

                if (angleDeg < SLOPE_STEEP_ANGLE) {
                    this.onGround = true;
                    this.onSlope  = true;
                    this.currentPlatform = p;
                    this.currentSlopeAngle   = angleDeg;
                    this.currentSlopeNormalX = nx;
                    this.currentSlopeNormalY = ny;

                    if (!this.isTipping) {
                        const slopeSign = nx > 0 ? 1 : -1;
                        this.targetTilt = slopeSign * angleDeg;
                    }
                } else {
                    const slideDir = nx > 0 ? 1 : -1;
                    this.velX += slideDir * SLOPE_EJECT_SPEED;
                }
            } else if (ny > 0.2) {
                if (this.velY < 0) this.velY = 0;
            } else {
                this.velX = 0;
            }
        }
    }

    draw(ctx) {
        let pivotX = this.x + this.width / 2;
        let pivotY = this.y + this.height;

        if (this.isTipping && this.currentPlatform) {
            const p = this.currentPlatform;
            const bx = p.x + p.width / 2;
            const by = p.y + p.height / 2;
            const rad = p.rotation * Math.PI / 180;
            const cos = Math.cos(rad), sin = Math.sin(rad);
            const hw = p.width / 2, hh = p.height / 2;

            const dir = this.tipVel > 0 ? 1 : -1;
            const px = dir > 0 ? hw : -hw;
            const py = -hh;

            pivotX = bx + px * cos - py * sin;
            pivotY = by + px * sin + py * cos;
        } else if (this.onSlope || this.slopeCoyote > 0) {
            if (this.currentSlopeNormalX < 0) {
                pivotX = this.x + this.width;
            } else if (this.currentSlopeNormalX > 0) {
                pivotX = this.x;
            }
        }

        ctx.save();
        ctx.translate(pivotX, pivotY);
        ctx.rotate(this.tilt * Math.PI / 180);
        ctx.translate(-pivotX, -pivotY);

        ctx.fillStyle = "#ffffff";
        ctx.fillRect(this.x, this.y, this.width, this.height);

        const eyeSize = this.width * 0.14;
        const eyeY    = this.y + this.height * 0.28;
        const exc     = this.x + this.width / 2 + this.facing * this.width * 0.12;

        ctx.fillStyle = "#1a1a1a";
        ctx.fillRect(exc - this.width * 0.22, eyeY, eyeSize, eyeSize);
        ctx.fillRect(exc + this.width * 0.22 - eyeSize, eyeY, eyeSize, eyeSize);

        ctx.restore();
    }
}

// ====== ROTATED COLLISION (SAT) ======
function blockCorners(p) {
    const cx = p.x + p.width / 2;
    const cy = p.y + p.height / 2;
    const rad = p.rotation * Math.PI / 180;
    const cos = Math.cos(rad), sin = Math.sin(rad);
    const hw = p.width / 2, hh = p.height / 2;
    return [
        { x: cx + (-hw) * cos - (-hh) * sin, y: cy + (-hw) * sin + (-hh) * cos },
        { x: cx + ( hw) * cos - (-hh) * sin, y: cy + ( hw) * sin + (-hh) * cos },
        { x: cx + ( hw) * cos - ( hh) * sin, y: cy + ( hw) * sin + ( hh) * cos },
        { x: cx + (-hw) * cos - ( hh) * sin, y: cy + (-hw) * sin + ( hh) * cos }
    ];
}

function rectCorners(r) {
    return [
        { x: r.x, y: r.y },
        { x: r.x + r.width, y: r.y },
        { x: r.x + r.width, y: r.y + r.height },
        { x: r.x, y: r.y + r.height }
    ];
}

function project(points, nx, ny) {
    let min = Infinity, max = -Infinity;
    for (const c of points) {
        const v = c.x * nx + c.y * ny;
        if (v < min) min = v;
        if (v > max) max = v;
    }
    return [min, max];
}

function satCollide(rect, block) {
    const rc = rectCorners(rect);
    const bc = blockCorners(block);

    const axes = [{ x: 1, y: 0 }, { x: 0, y: 1 }];
    for (let i = 0; i < 4; i++) {
        const p1 = bc[i];
        const p2 = bc[(i + 1) % 4];
        const ex = p2.x - p1.x, ey = p2.y - p1.y;
        const len = Math.hypot(ex, ey);
        if (len > 0) axes.push({ x: -ey / len, y: ex / len });
    }

    let minOverlap = Infinity;
    let bestAxis = null;

    for (const a of axes) {
        const [minA, maxA] = project(rc, a.x, a.y);
        const [minB, maxB] = project(bc, a.x, a.y);
        if (maxA < minB || maxB < minA) return null;
        const ov = Math.min(maxA, maxB) - Math.max(minA, minB);
        if (ov < minOverlap) {
            minOverlap = ov;
            bestAxis = { x: a.x, y: a.y };
        }
    }

    const rcx = rect.x + rect.width / 2;
    const rcy = rect.y + rect.height / 2;
    const bcx = block.x + block.width / 2;
    const bcy = block.y + block.height / 2;
    const d = (rcx - bcx) * bestAxis.x + (rcy - bcy) * bestAxis.y;
    if (d < 0) { bestAxis.x *= -1; bestAxis.y *= -1; }

    return { axis: bestAxis, depth: minOverlap };
}

// ====== CAMERA ======
const camera = {
    x: 0,
    y: 0,
    follow(target) {
        const targetX = target.x + target.width  / 2 - VIEW_WIDTH  / 2;
        const targetY = target.y + target.height / 2 - VIEW_HEIGHT / 2;

        this.x = clamp(targetX, 0, WORLD_WIDTH  - VIEW_WIDTH);
        this.y = clamp(targetY, 0, WORLD_HEIGHT - VIEW_HEIGHT);
    }
};

// ====== GLOBAL VARIABLES ======
let playerObj;
let gameStarted = false;
let isPaused = false;

const keys = { w: false, a: false, s: false, d: false, space: false, p: false };

// ====== HELPER FUNCTIONS ======
function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(v, hi));
}

function isColliding(a, b) {
    return a.x < b.x + b.width  &&
           a.x + a.width  > b.x &&
           a.y < b.y + b.height &&
           a.y + a.height > b.y;
}

// ====== TRANSITIONS ======
function startGame() {
    gameStarted = true;
    isPaused = false;

    const spawnX = 60;
    const spawnY = WORLD_HEIGHT - 140;

    playerObj = new Player(spawnX, spawnY);
    camera.follow(playerObj);
}

function init() {
    gameArea.setup();
    startGame();
}

// ====== GAME AREA ENGINE ======
const gameArea = {
    canvas: document.getElementById("gameCanvas"),
    width: VIEW_WIDTH,
    height: VIEW_HEIGHT,
    scale: 1,
    offsetX: 0,
    offsetY: 0,

    setup() {
        this.context = this.canvas.getContext("2d");
        this.resize();
        buildLevel();
        lastTimestamp = performance.now();
        requestAnimationFrame(engineLoop);
    },

    resize() {
        const dpr  = window.devicePixelRatio || 1;
        const cssW = window.innerWidth;
        const cssH = window.innerHeight;

        this.canvas.style.width  = cssW + "px";
        this.canvas.style.height = cssH + "px";
        this.canvas.width  = Math.round(cssW * dpr);
        this.canvas.height = Math.round(cssH * dpr);

        this.scale = Math.min(
            this.canvas.width  / this.width,
            this.canvas.height / this.height
        );

        this.offsetX = (this.canvas.width  - this.width  * this.scale) / 2;
        this.offsetY = (this.canvas.height - this.height * this.scale) / 2;
    }
};

// ====== UPDATE GAME ======
function update() {
    if (!gameStarted || isPaused || !playerObj) return;

    playerObj.update();
    camera.follow(playerObj);
}

// ====== RENDER VISUALS ======
function renderGame() {
    const ctx = gameArea.context;
    if (!ctx) return;

    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = "#000000";
    ctx.fillRect(0, 0, gameArea.canvas.width, gameArea.canvas.height);

    if (!gameStarted || !playerObj) return;

    const s = gameArea.scale;

    ctx.save();
    ctx.setTransform(s, 0, 0, s, gameArea.offsetX - camera.x * s, gameArea.offsetY - camera.y * s);

    ctx.beginPath();
    ctx.rect(camera.x, camera.y, VIEW_WIDTH, VIEW_HEIGHT);
    ctx.clip();

    drawWorld(ctx);
    playerObj.draw(ctx);

    ctx.restore();

    ctx.save();
    ctx.setTransform(s, 0, 0, s, gameArea.offsetX, gameArea.offsetY);
    drawHud(ctx);
    ctx.restore();
}

function drawWorld(ctx) {
    const viewRight  = camera.x + VIEW_WIDTH;
    const viewBottom = camera.y + VIEW_HEIGHT;

    ctx.fillStyle = "#1a1a1a";
    ctx.fillRect(camera.x, camera.y, VIEW_WIDTH, VIEW_HEIGHT);

    const GRID = 240;
    ctx.strokeStyle = "#242424";
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let x = Math.floor(camera.x / GRID) * GRID; x <= viewRight; x += GRID) {
        ctx.moveTo(x, camera.y);
        ctx.lineTo(x, viewBottom);
    }
    for (let y = Math.floor(camera.y / GRID) * GRID; y <= viewBottom; y += GRID) {
        ctx.moveTo(camera.x, y);
        ctx.lineTo(viewRight, y);
    }
    ctx.stroke();

    ctx.strokeStyle = "#3a3a3a";
    ctx.lineWidth = 4;
    ctx.beginPath();
    for (let x = 0; x <= WORLD_WIDTH; x += SCREEN_WIDTH) {
        ctx.moveTo(x, camera.y);
        ctx.lineTo(x, viewBottom);
    }
    for (let y = 0; y <= WORLD_HEIGHT; y += SCREEN_HEIGHT) {
        ctx.moveTo(camera.x, y);
        ctx.lineTo(viewRight, y);
    }
    ctx.stroke();

    for (const p of platforms) {
        if (!p.rotation) {
            if (p.x + p.width  < camera.x || p.x > viewRight)  continue;
            if (p.y + p.height < camera.y || p.y > viewBottom) continue;
        } else {
            const diag = Math.hypot(p.width, p.height);
            const cx = p.x + p.width / 2;
            const cy = p.y + p.height / 2;
            if (cx + diag < camera.x || cx - diag > viewRight)  continue;
            if (cy + diag < camera.y || cy - diag > viewBottom) continue;
        }

        if (!p.rotation) {
            ctx.fillStyle = "#3b7dd8";
            ctx.fillRect(p.x, p.y, p.width, p.height);
            ctx.fillStyle = "#5aa0ff";
            ctx.fillRect(p.x, p.y, p.width, 8);
        } else {
            const cx = p.x + p.width / 2;
            const cy = p.y + p.height / 2;
            ctx.save();
            ctx.translate(cx, cy);
            ctx.rotate(p.rotation * Math.PI / 180);
            ctx.fillStyle = "#3b7dd8";
            ctx.fillRect(-p.width / 2, -p.height / 2, p.width, p.height);
            ctx.fillStyle = "#5aa0ff";
            ctx.fillRect(-p.width / 2, -p.height / 2, p.width, 8);
            ctx.restore();
        }
    }
}

function drawHud(ctx) {
    ctx.textBaseline = "top";

    if (isPaused) {
        ctx.fillStyle = "rgba(0, 0, 0, 0.55)";
        ctx.fillRect(0, 0, VIEW_WIDTH, VIEW_HEIGHT);
        ctx.fillStyle = "#ffffff";
        ctx.font = "bold 96px monospace";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText("PAUSED", VIEW_WIDTH / 2, VIEW_HEIGHT / 2);
        ctx.textAlign = "left";
        ctx.textBaseline = "top";
    }
}

// ====== ENGINE LOOP ======
function engineLoop(currentTime) {
    let deltaTime = currentTime - lastTimestamp;
    lastTimestamp = currentTime;

    if (!Number.isFinite(deltaTime) || deltaTime < 0) deltaTime = 0;
    if (deltaTime > 250) deltaTime = 250;

    frameAccumulator += deltaTime;

    let steps = 0;
    while (frameAccumulator >= tickLength && steps < 10) {
        update();
        frameAccumulator -= tickLength;
        steps++;
    }
    if (steps === 10) frameAccumulator = 0;

    renderGame();
    requestAnimationFrame(engineLoop);
}

// ====== KEYBOARD LISTENERS ======
function normalizeKey(e) {
    const k = e.key.toLowerCase();
    if (k === " " || k === "spacebar") return "space";
    if (k === "arrowleft")  return "a";
    if (k === "arrowright") return "d";
    if (k === "arrowup")    return "w";
    if (k === "arrowdown")  return "s";
    return k;
}

document.addEventListener("keydown", e => {
    const key = normalizeKey(e);
    if (!(key in keys)) return;

    if (e.key === " " || e.key.startsWith("Arrow")) e.preventDefault();

    if (key === "p" && !e.repeat) isPaused = !isPaused;
    keys[key] = true;
});

document.addEventListener("keyup", e => {
    const key = normalizeKey(e);
    if (!(key in keys)) return;

    if (e.key === " " || e.key.startsWith("Arrow")) e.preventDefault();
    keys[key] = false;
});

window.addEventListener("blur", () => {
    for (const k in keys) keys[k] = false;
});

window.addEventListener("resize", () => {
    gameArea.resize();
});

window.addEventListener("load", init);