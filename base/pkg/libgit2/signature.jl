function Signature(ptr::Ptr{SignatureStruct})
    sig   = unsafe_load(ptr)::SignatureStruct
    name  = bytestring(sig.name)
    email = bytestring(sig.email)
    time   = sig.when.time
    offset = sig.when.offset
    return Signature(name, email, time, offset)
end
Signature(sig::GitSignature) = Signature(sig.ptr)

function Signature(name::AbstractString, email::AbstractString)
    sig_ptr_ptr = Ref{Ptr{SignatureStruct}}(C_NULL)
    @check ccall((:git_signature_now, :libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{UInt8}, Ptr{UInt8}), sig_ptr_ptr, name, email)
    sig = GitSignature(sig_ptr_ptr[])
    s = Signature(sig.ptr)
    finalize(sig)
    return s
end

function Signature(repo::GitRepo)
    sig_ptr_ptr = Ref{Ptr{SignatureStruct}}(C_NULL)
    @check ccall((:git_signature_default, :libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{Void}), sig_ptr_ptr, repo.ptr)
    sig = GitSignature(sig_ptr_ptr[])
    s = Signature(sig.ptr)
    finalize(sig)
    return s
end

function Base.convert(::Type{GitSignature}, sig::Signature)
    sig_ptr_ptr = Ref{Ptr{SignatureStruct}}(C_NULL)
    @check ccall((:git_signature_new, :libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{Uint8}, Ptr{Uint8}, Cint, Cint),
                 sig_ptr_ptr, sig.name, sig.email, sig.time, sig.time_offset)
    return GitSignature(sig_ptr_ptr[])
end