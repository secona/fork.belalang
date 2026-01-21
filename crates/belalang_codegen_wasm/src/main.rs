use walrus::ir::*;
use walrus::{FunctionBuilder, Module, ModuleConfig, ValType};

fn main() -> walrus::Result<()> {
    let config = ModuleConfig::new();
    let mut module = Module::with_config(config);

    let log_type = module.types.add(&[ValType::I32], &[]);
    let (log, _) = module.add_import_func("env", "log", log_type);

    let mut factorial = FunctionBuilder::new(&mut module.types, &[ValType::I32], &[ValType::I32]);

    let n = module.locals.add(ValType::I32);
    let i = module.locals.add(ValType::I32);
    let res = module.locals.add(ValType::I32);

    factorial
        .func_body()
        .local_get(n)
        .local_set(i)
        .i32_const(1)
        .local_set(res)
        .block(None, |done| {
            let done_id = done.id();
            done.loop_(None, |loop_| {
                let loop_id = loop_.id();
                loop_
                    .local_get(res)
                    .call(log)
                    .local_get(i)
                    .i32_const(0)
                    .binop(BinaryOp::I32Eq)
                    .if_else(
                        None, 
                        |then| {
                            then.br(done_id);
                        },
                        |else_| {
                            else_
                                .local_get(i)
                                .local_get(res)
                                .binop(BinaryOp::I32Mul)
                                .local_set(res)
                                .local_get(i)
                                .i32_const(1)
                                .binop(BinaryOp::I32Sub)
                                .local_set(i);
                        }
                    )
                    .br(loop_id);
            });
        })
        .local_get(res);

    let factorial = factorial.finish(vec![n], &mut module.funcs);

    module.exports.add("factorial", factorial);
    module.emit_wasm_file("target/out.wasm")
}
