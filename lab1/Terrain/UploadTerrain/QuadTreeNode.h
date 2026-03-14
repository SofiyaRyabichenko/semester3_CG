#pragma once

#include <DirectXMath.h>
#include <DirectXCollision.h>
#include <vector>
#include <memory>

// Структура данных патча для рендеринга
struct PatchData {
    DirectX::XMFLOAT2 offset;      // позиция патча в мировых координатах (X, Z)
    float size;                     // размер патча в метрах
    float distanceToCamera;         // расстояние до камеры
    int lodLevel;                   // уровень детализации (0 = самый детальный)
    
    PatchData() 
        : offset(0.0f, 0.0f)
        , size(0.0f)
        , distanceToCamera(0.0f)
        , lodLevel(0)
    {}
};

// Узел квадро-дерева для адаптивного LOD террейна
class QuadTreeNode {
public:
    // Границы узла (AABB в XZ плоскости)
    struct Bounds {
        DirectX::XMFLOAT3 center;   // центр узла (Y используется для высоты террейна)
        float halfSize;              // половина размера узла (в метрах)
        
        Bounds() : center(0.0f, 0.0f, 0.0f), halfSize(0.0f) {}
        Bounds(const DirectX::XMFLOAT3& c, float hs) : center(c), halfSize(hs) {}
        
        // Получить полный размер узла
        float GetSize() const { return halfSize * 2.0f; }
        
        // Получить минимальную точку (для BoundingBox)
        DirectX::XMFLOAT3 GetMin() const {
            return DirectX::XMFLOAT3(
                center.x - halfSize,
               - 10.0f,  // примерная высота для frustum culling
                center.z - halfSize
            );
        }
        
        // Получить максимальную точку (для BoundingBox)
        DirectX::XMFLOAT3 GetMax() const {
            return DirectX::XMFLOAT3(
                center.x + halfSize,
                60.0f,  // примерная высота для frustum culling
                center.z + halfSize
            );
        }
    };

private:
    Bounds m_bounds;                        // границы этого узла
    QuadTreeNode* m_children[4];            // 4 дочерних узла: [0]=NW, [1]=NE, [2]=SW, [3]=SE
    int m_level;                            // уровень в дереве (0 = корень)
    bool m_isLeaf;                          // является ли узел листом (нет детей)
    
    static constexpr int MAX_TREE_DEPTH = 4; // максимальная глубина дерева (0-4 = 5 уровней)

public:
    QuadTreeNode(const Bounds& bounds, int level = 0)
        : m_bounds(bounds)
        , m_level(level)
        , m_isLeaf(true)
    {
        for (int i = 0; i < 4; ++i) {
            m_children[i] = nullptr;
        }
    }

    ~QuadTreeNode() {
        Clear();
    }

    // Запретить копирование
    QuadTreeNode(const QuadTreeNode&) = delete;
    QuadTreeNode& operator=(const QuadTreeNode&) = delete;

    // Разделить узел на 4 дочерних
    void Subdivide() {
        if (!m_isLeaf || m_level >= MAX_TREE_DEPTH) {
            return; // уже разделен или достигнута максимальная глубина
        }

        float childHalfSize = m_bounds.halfSize * 0.5f;
        float quarterSize = childHalfSize;
        int childLevel = m_level + 1;

        // Создаем 4 дочерних узла
        // [0] = North-West (верхний левый)
        m_children[0] = new QuadTreeNode(
            Bounds(
                DirectX::XMFLOAT3(
                    m_bounds.center.x - quarterSize,
                    m_bounds.center.y,
                    m_bounds.center.z + quarterSize
                ),
                childHalfSize
            ),
            childLevel
        );

        // [1] = North-East (верхний правый)
        m_children[1] = new QuadTreeNode(
            Bounds(
                DirectX::XMFLOAT3(
                    m_bounds.center.x + quarterSize,
                    m_bounds.center.y,
                    m_bounds.center.z + quarterSize
                ),
                childHalfSize
            ),
            childLevel
        );

        // [2] = South-West (нижний левый)
        m_children[2] = new QuadTreeNode(
            Bounds(
                DirectX::XMFLOAT3(
                    m_bounds.center.x - quarterSize,
                    m_bounds.center.y,
                    m_bounds.center.z - quarterSize
                ),
                childHalfSize
            ),
            childLevel
        );

        // [3] = South-East (нижний правый)
        m_children[3] = new QuadTreeNode(
            Bounds(
                DirectX::XMFLOAT3(
                    m_bounds.center.x + quarterSize,
                    m_bounds.center.y,
                    m_bounds.center.z - quarterSize
                ),
                childHalfSize
            ),
            childLevel
        );

        m_isLeaf = false;
    }

    // Проверить, нужно ли разделить узел на основе расстояния до камеры
    bool ShouldSubdivide(const DirectX::XMFLOAT3& cameraPos, float minNodeSize) const {
        if (m_level >= MAX_TREE_DEPTH) {
            return false;
        }

        if (m_bounds.GetSize() <= minNodeSize) {
            return false;
        }

        // ИСПОЛЬЗУЕМ 3D РАССТОЯНИЕ (включая высоту камеры)
        float dx = cameraPos.x - m_bounds.center.x;
        float dy = cameraPos.y - m_bounds.center.y; 
        float dz = cameraPos.z - m_bounds.center.z;
        float distanceToCamera = sqrtf(dx * dx + dy * dy + dz * dz);  // 3D расстояние

        // АДАПТИВНЫЙ ПОРОГ: зависит от размера узла И расстояния
        // Чем больше узел, тем на большем расстоянии его нужно делить
        float subdivisionThreshold = m_bounds.GetSize() * 4.0f;  // можно настроить 2.0-5.0

        return distanceToCamera < subdivisionThreshold;
    }

    // Проверить, находится ли узел во frustum камеры
    bool IsInFrustum(const DirectX::BoundingFrustum& frustum) const {
        // Создаем BoundingBox для этого узла
        DirectX::XMFLOAT3 minPoint = m_bounds.GetMin();
        DirectX::XMFLOAT3 maxPoint = m_bounds.GetMax();
        
        DirectX::XMFLOAT3 center(
            (minPoint.x + maxPoint.x) * 0.5f,
            (minPoint.y + maxPoint.y) * 0.5f,
            (minPoint.z + maxPoint.z) * 0.5f
        );
        
        DirectX::XMFLOAT3 extents(
            (maxPoint.x - minPoint.x) * 0.5f,
            (maxPoint.y - minPoint.y) * 0.5f,
            (maxPoint.z - minPoint.z) * 0.5f
        );
        
        DirectX::BoundingBox box(center, extents);
        
        // Проверяем пересечение с frustum
        return frustum.Intersects(box);
    }

    // Рекурсивно собрать все видимые патчи для рендеринга
    void CollectVisiblePatches(
        const DirectX::XMFLOAT3& cameraPos,
        const DirectX::BoundingFrustum& frustum,
        float minNodeSize,
        std::vector<PatchData>& outPatches)
    {
        // Frustum culling - если узел не виден, пропускаем его и всех детей
        if (!IsInFrustum(frustum)) {
            return;
        }

        // Проверяем, нужно ли разделить этот узел
        if (ShouldSubdivide(cameraPos, minNodeSize)) {
            // Узел близко к камере - нужно разделить
            if (m_isLeaf) {
                Subdivide();
            }

            // Рекурсивно обрабатываем дочерние узлы
            if (!m_isLeaf) {
                for (int i = 0; i < 4; ++i) {
                    if (m_children[i]) {
                        m_children[i]->CollectVisiblePatches(cameraPos, frustum, minNodeSize, outPatches);
                    }
                }
            }
        }
        else {
            // Узел достаточно далеко - рисуем его как один патч
            // Если у узла есть дети, удаляем их
            if (!m_isLeaf) {
                Clear();
            }

            // Создаем данные патча для рендеринга
            PatchData patch;

            // Offset - это левый нижний угол патча
            patch.offset.x = m_bounds.center.x - m_bounds.halfSize;
            patch.offset.y = m_bounds.center.z - m_bounds.halfSize;

            patch.size = m_bounds.GetSize();

            // Вычисляем расстояние до камеры
            float dx = cameraPos.x - m_bounds.center.x;
            float dz = cameraPos.z - m_bounds.center.z;
            patch.distanceToCamera = sqrtf(dx * dx + dz * dz);

            //LOD LEVEL: близко = 4, далеко = 0
            patch.lodLevel = m_level;  

            outPatches.push_back(patch);
        }
    }

    // Удалить всех детей (сделать узел листом)
    void Clear() {
        for (int i = 0; i < 4; ++i) {
            if (m_children[i]) {
                delete m_children[i];
                m_children[i] = nullptr;
            }
        }
        m_isLeaf = true;
    }

    // Получить границы узла
    const Bounds& GetBounds() const { return m_bounds; }
    
    // Получить уровень узла
    int GetLevel() const { return m_level; }
    
    // Является ли узел листом
    bool IsLeaf() const { return m_isLeaf; }

    // Получить количество узлов в дереве (для отладки)
    int GetNodeCount() const {
        int count = 1; // этот узел
        if (!m_isLeaf) {
            for (int i = 0; i < 4; ++i) {
                if (m_children[i]) {
                    count += m_children[i]->GetNodeCount();
                }
            }
        }
        return count;
    }

    // Получить общее количество листовых узлов (патчей) в дереве
    int GetTotalPatchCount() const {
        if (m_isLeaf) {
            return 1;  // это лист = один патч
        }

        int count = 0;
        for (int i = 0; i < 4; ++i) {
            if (m_children[i]) {
                count += m_children[i]->GetTotalPatchCount();
            }
        }
        return count;
    }
};
