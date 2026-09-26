export class MatrixUtils {
  static identity(): number[] {
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  }

  static translate(matrix: number[], tx: number, ty: number): number[] {
    const result = [...matrix];
    result[12] += tx;
    result[13] += ty;
    return result;
  }

  static scale(matrix: number[], sx: number, sy: number): number[] {
    const result = [...matrix];
    result[0] *= sx;
    result[5] *= sy;
    return result;
  }

  static multiply(a: number[], b: number[]): number[] {
    const result: number[] = new Array(16).fill(0);
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) {
        for (let k = 0; k < 4; k++) {
          result[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j];
        }
      }
    }
    return result;
  }
}
