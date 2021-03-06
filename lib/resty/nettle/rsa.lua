require "resty.nettle.library"
require "resty.nettle.types.md5"
require "resty.nettle.types.sha1"
require "resty.nettle.types.sha2"

local mpz = require "resty.nettle.mpz"
local random = require "resty.nettle.random"
local types = require "resty.nettle.types.common"
local context = require "resty.nettle.types.rsa"
local hogweed = require "resty.nettle.hogweed"
local ffi = require "ffi"
local ffi_gc = ffi.gc
local ffi_new = ffi.new
local ffi_str = ffi.string
local setmetatable = setmetatable

local sig = mpz.new()

local public = {}
public.__index = public

function public.new(n, e)
  local ctx = ffi_gc(ffi_new(context.public), hogweed.nettle_rsa_public_key_clear)
  hogweed.nettle_rsa_public_key_init(ctx)
  if n then
    local ok, err = mpz.set(ctx.n, n)
    if not ok then
      return nil, "unable to set RSA public key (" .. err .. ")"
    end
  end
  if e then
    local ok, err = mpz.set(ctx.e, e)
    if not ok then
      return nil, "unable to set RSA public exponent (" .. err .. ")"
    end
  end
  if n and e then
    if hogweed.nettle_rsa_public_key_prepare(ctx) ~= 1 then
      return nil, "unable to prepare RSA public key"
    end
  end
  return setmetatable({ context = ctx }, public)
end

function public:e()
  return mpz.tostring(self.context.e)
end

function public:n()
  return mpz.tostring(self.context.n)
end

local private = {}
private.__index = private

function private.new(d, p, q, a, b, c)
  local ctx = ffi_gc(ffi_new(context.private), hogweed.nettle_rsa_private_key_clear)
  hogweed.nettle_rsa_private_key_init(ctx)
  if d then
    local ok, err = mpz.set(ctx.d, d)
    if not ok then
      return nil, "unable to set RSA private key exponent (" .. err .. ")"
    end
  end
  local p1
  if p then
    local ok, err = mpz.set(ctx.p, p)
    if not ok then
      return nil, "unable to set RSA factor p (" .. err .. ")"
    end

    if d and not a then
      p1 = mpz.new()
      mpz.sub(p1, ctx.p, 1)
    end
  end
  local q1
  if q then
    local ok, err = mpz.set(ctx.q, q)
    if not ok then
      return nil, "unable to set RSA factor q (" .. err .. ")"
    end

    if d and not b then
      q1 = mpz.new()
      mpz.sub(q1, ctx.q, 1)
    end
  end
  if a then
    local ok, err = mpz.set(ctx.a, a)
    if not ok then
      return nil, "unable to set RSA parameter a (" .. err .. ")"
    end
  elseif p1 then
    mpz.div(ctx.a, ctx.d, p1)
  end
  if b then
    local ok, err = mpz.set(ctx.b, b)
    if not ok then
      return nil, "unable to set RSA parameter b (" .. err .. ")"
    end
  elseif q1 then
    mpz.div(ctx.b, ctx.d, q1)
  end
  if c then
    local ok, err = mpz.set(ctx.c, c)
    if not ok then
      return nil, "unable to set RSA parameter c (" .. err .. ")"
    end
  elseif q and p then
    if mpz.invert(ctx.c, ctx.q, ctx.p) == 0 then
      mpz.invert(ctx.c, ctx.q, ctx.p) -- try again once
    end
  end
  if d or p or q or a or b or c then
    if hogweed.nettle_rsa_private_key_prepare(ctx) ~= 1 then
      return nil, "unable to prepare an RSA private key"
    end
  end
  return setmetatable({ context = ctx }, private)
end

function private:d()
  return mpz.tostring(self.context.d)
end

function private:p()
  return mpz.tostring(self.context.p)
end

function private:q()
  return mpz.tostring(self.context.q)
end

function private:a()
  return mpz.tostring(self.context.a)
end

function private:b()
  return mpz.tostring(self.context.b)
end

function private:c()
  return mpz.tostring(self.context.c)
end

local keypair = {}

keypair.__index = keypair

function keypair.new(n_size, e)
  local pux, err = public.new(nil, e or 65537)
  if not pux then
    return nil, err
  end
  local prx
  prx, err = private.new()
  if not prx then
    return nil, err
  end
  if hogweed.nettle_rsa_generate_keypair(pux.context,
                                         prx.context,
                                         random.context,
                                         random.func,
                                         nil,
                                         nil,
                                         n_size or 4096,
                                         0) ~= 1 then
    return nil, "unable to generate RSA keypair"
  end

  return setmetatable({
    public  = pux,
    private = prx
  }, keypair)

end

function keypair.der(data)
  local pux = public.new()
  local prx = private.new()
  if hogweed.nettle_rsa_keypair_from_der(pux.context,
                                         prx.context,
                                         0, #data, data) ~= 1 then
    return nil, "unable to generate RSA keypair from DER"
  end
  return setmetatable({
    public = pux,
    private = prx
  }, keypair)
end

local rsa = { keypair = keypair, key = { public = public, private = private } }
rsa.__index = rsa

function rsa.new(pub, pri)
  if not pub and not pri then
    local kp = keypair.new()
    pub = kp.public
    pri = kp.private
  end
  return setmetatable({ public = pub, private = pri }, rsa)
end

function rsa:encrypt(plain)
  local encrypted, err = mpz.new()
  if not encrypted then
    return nil, err
  end

  local len = #plain
  local max_len = self.public.context.size - 11

  if len > max_len then
    return nil, "cannot encrypt message larger than key size / 8 - 11 with PKCS#1 v1.5 padding"
  end

  if hogweed.nettle_rsa_encrypt(self.public.context,
                                random.context,
                                random.func,
                                len,
                                plain,
                                encrypted) ~= 1 then
    return nil, "unable to RSA encrypt"
  end

  return mpz.tostring(encrypted, self.public.context.size)
end

function rsa:decrypt(encrypted, outlen)
  if self.public then
    if outlen then
      return self:decrypt_sec(encrypted, outlen)
    end

    return self:decrypt_tr(encrypted)
  end
  local ct, err = mpz.new(encrypted)
  if not ct then
    return nil, err
  end
  local sz = self.private.context.size
  local b = ffi_new(types.uint8_t, sz)
  types.size_t_8[0] = sz
  if hogweed.nettle_rsa_decrypt(self.private.context, types.size_t_8, b, ct) ~= 1 then
    return nil, "unable to RSA decrypt"
  end
  return ffi_str(b, types.size_t_8[0])
end

function rsa:decrypt_tr(encrypted)
  local ct, err = mpz.new(encrypted)
  if not ct then
    return nil, err
  end
  local sz = self.private.context.size
  local b = ffi_new(types.uint8_t, sz)
  types.size_t_8[0] = sz
  if hogweed.nettle_rsa_decrypt_tr(self.public.context,
                                   self.private.context,
                                   random.context,
                                   random.func,
                                   types.size_t_8,
                                   b,
                                   ct) ~= 1 then
    return nil, "unable to RSA decrypt"
  end
  return ffi_str(b, types.size_t_8[0])
end

function rsa:decrypt_sec(encrypted, outlen)
  local ct, err = mpz.new(encrypted)
  if not ct then
    return nil, err
  end
  local b = ffi_new(types.uint8_t, outlen)
  if hogweed.nettle_rsa_sec_decrypt(self.public.context,
                                    self.private.context,
                                    random.context,
                                    random.func,
                                    outlen,
                                    b,
                                    ct) ~= 1 then
    return nil, "unable to RSA decrypt"
  end
  return ffi_str(b, outlen)
end

function rsa:sign_digest(digest)
  if self.public then
    return self:sign_digest_tr(digest)
  end

  local l = #digest
  if l == 16 then
    if hogweed.nettle_rsa_md5_sign_digest(self.private.context, digest, sig) ~= 1 then
      return nil, "unable to RSA MD5 sign"
    end
  elseif l == 20 then
    if hogweed.nettle_rsa_sha1_sign_digest(self.private.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA1 sign"
    end
  elseif l == 32 then
    if hogweed.nettle_rsa_sha256_sign_digest(self.private.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA256 sign"
    end
  elseif l == 64 then
    if hogweed.nettle_rsa_sha512_sign_digest(self.private.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA512 sign"
    end
  else
    return nil, "supported RSA digests for signing are MD5, SHA1, SHA256, and SHA512"
  end

  local size
  if self.private then
    size = self.private.context.size
  elseif self.public then
    size = self.public.context.size
  end

  return mpz.tostring(sig, size)
end

function rsa:sign_digest_tr(digest)
  local l = #digest
  if l == 16 then
    if hogweed.nettle_rsa_md5_sign_digest_tr(self.public.context,
                                             self.private.context,
                                             random.context,
                                             random.func,
                                             digest,
                                             sig) ~= 1 then
      return nil, "unable to RSA MD5 sign digest with blinding"
    end
  elseif l == 20 then
    if hogweed.nettle_rsa_sha1_sign_digest_tr(self.public.context,
                                              self.private.context,
                                              random.context,
                                              random.func,
                                              digest,
                                              sig) ~= 1 then
      return nil, "unable to RSA SHA1 sign digest with blinding"
    end
  elseif l == 32 then
    if hogweed.nettle_rsa_sha256_sign_digest_tr(self.public.context,
                                                self.private.context,
                                                random.context,
                                                random.func,
                                                digest,
                                                sig) ~= 1 then
      return nil, "unable to RSA SHA256 sign digest with blinding"
    end
  elseif l == 64 then
    if hogweed.nettle_rsa_sha512_sign_digest_tr(self.public.context,
                                                self.private.context,
                                                random.context,
                                                random.func,
                                                digest,
                                                sig) ~= 1 then
      return nil, "unable to RSA SHA512 sign digest with blinding"
    end
  else
    return nil, "supported RSA digests with blinding are MD5, SHA1, SHA256, and SHA512"
  end

  local size
  if self.private then
    size = self.private.context.size
  elseif self.public then
    size = self.public.context.size
  end

  return mpz.tostring(sig, size)
end

function rsa:verify_digest(digest, signature)
  mpz.set(sig, signature)
  local l = #digest
  if l == 16 then
    if hogweed.nettle_rsa_md5_verify_digest(self.public.context, digest, sig) ~= 1 then
      return nil, "unable to RSA MD5 verify digest"
    end
  elseif l == 20 then
    if hogweed.nettle_rsa_sha1_verify_digest(self.public.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA1 verify digest"
    end
  elseif l == 32 then
    if hogweed.nettle_rsa_sha256_verify_digest(self.public.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA256 verify digest"
    end
  elseif l == 64 then
    if hogweed.nettle_rsa_sha512_verify_digest(self.public.context, digest, sig) ~= 1 then
      return nil, "unable to RSA SHA512 verify digest"
    end
  else
    return nil, "supported RSA digests are MD5, SHA1, SHA256, and SHA512"
  end
  return true
end

function rsa:pss_sign_digest(digest)
  local l = #digest
  if l == 32 then
    if hogweed.nettle_rsa_pss_sha256_sign_digest_tr(self.public.context,
                                                    self.private.context,
                                                    random.context,
                                                    random.func,
                                                    32,
                                                    random.bytes(32),
                                                    digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA256 sign digest"
    end
  elseif l == 48 then
    if hogweed.nettle_rsa_pss_sha384_sign_digest_tr(self.public.context,
                                                    self.private.context,
                                                    random.context,
                                                    random.func,
                                                    48,
                                                    random.bytes(48),
                                                    digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA384 sign digest"
    end
  elseif l == 64 then
    if hogweed.nettle_rsa_pss_sha512_sign_digest_tr(self.public.context,
                                                    self.private.context,
                                                    random.context,
                                                    random.func,
                                                    64,
                                                    random.bytes(64),
                                                    digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA512 sign digest"
    end
  else
    return nil, "supported RSA-PSS digests for signing are SHA256, SHA384, and SHA512"
  end

  local size
  if self.private then
    size = self.private.context.size
  elseif self.public then
    size = self.public.context.size
  end

  return mpz.tostring(sig, size)
end

function rsa:pss_verify_digest(digest, signature)
  mpz.set(sig, signature)
  local l = #digest
  if l == 32 then
    if hogweed.nettle_rsa_pss_sha256_verify_digest(self.public.context,
                                                   32,
                                                   digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA256 verify digest"
    end
  elseif l == 48 then
    if hogweed.nettle_rsa_pss_sha384_verify_digest(self.public.context,
                                                   48,
                                                   digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA384 verify digest"
    end
  elseif l == 64 then
    if hogweed.nettle_rsa_pss_sha512_verify_digest(self.public.context,
                                                   64,
                                                   digest, sig) ~= 1 then
      return nil, "unable to RSA-PSS SHA512 verify digest"
    end
  else
    return nil, "supported RSA-PSS digests are SHA256, SHA384, and SHA512"
  end
  return true
end

return rsa
