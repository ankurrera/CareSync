import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';

final medicalConditionsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final supabase = Supabase.instance.client;
  final userId = supabase.auth.currentUser?.id;
  
  if (userId == null) return [];
  
  // First get the patient id
  final patientResult = await supabase
      .from('patients')
      .select('id')
      .eq('user_id', userId)
      .maybeSingle();
  
  if (patientResult == null) return [];
  
  final patientId = patientResult['id'];
  
  // Then get medical conditions
  final conditions = await supabase
      .from('medical_conditions')
      .select()
      .eq('patient_id', patientId)
      .order('created_at', ascending: false);
  
  return List<Map<String, dynamic>>.from(conditions);
});

class MedicalHistoryScreen extends ConsumerWidget {
  const MedicalHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conditionsAsync = ref.watch(medicalConditionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Medical History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddConditionDialog(context, ref),
          ),
        ],
      ),
      body: conditionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: AppSpacing.screenPadding,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: AppColors.error.withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'Error loading medical history',
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => ref.refresh(medicalConditionsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        data: (conditions) {
          if (conditions.isEmpty) {
            return _buildEmptyState(context, ref);
          }
          return ListView.builder(
            padding: AppSpacing.screenPadding,
            itemCount: conditions.length,
            itemBuilder: (context, index) {
              final condition = conditions[index];
              return _buildConditionCard(context, condition, ref);
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: AppSpacing.screenPadding,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.medical_information_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.2),
            ),
            const SizedBox(height: 24),
            Text(
              'No Medical Conditions',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add your allergies, chronic conditions, and other medical information for emergency access',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showAddConditionDialog(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add Condition'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConditionCard(BuildContext context, Map<String, dynamic> condition, WidgetRef ref) {
    final type = condition['condition_type'] as String;
    final severity = condition['severity'] as String?;
    final isPublic = condition['is_public'] as bool? ?? true;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getTypeColor(type).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _formatType(type),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _getTypeColor(type),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (severity != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getSeverityColor(severity).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      severity.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _getSeverityColor(severity),
                      ),
                    ),
                  ),
                const Spacer(),
                Icon(
                  isPublic ? Icons.public : Icons.lock,
                  size: 18,
                  color: isPublic ? AppColors.success : AppColors.warning,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              condition['description'] ?? '',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  isPublic ? 'Visible to first responders' : 'Private',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.error,
                  onPressed: () => _deleteCondition(context, ref, condition['id']),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'allergy':
        return AppColors.error;
      case 'chronic':
        return AppColors.warning;
      case 'medication':
        return AppColors.pharmacist;
      default:
        return AppColors.info;
    }
  }

  String _formatType(String type) {
    switch (type) {
      case 'allergy':
        return 'ALLERGY';
      case 'chronic':
        return 'CHRONIC';
      case 'medication':
        return 'MEDICATION';
      default:
        return 'OTHER';
    }
  }

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'critical':
        return AppColors.error;
      case 'severe':
        return Colors.deepOrange;
      case 'moderate':
        return AppColors.warning;
      default:
        return AppColors.success;
    }
  }

  Future<void> _showAddConditionDialog(BuildContext context, WidgetRef ref) async {
    final descriptionController = TextEditingController();
    String selectedType = 'allergy';
    String selectedSeverity = 'moderate';
    bool isPublic = true;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add Medical Condition',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'allergy', child: Text('Allergy')),
                  DropdownMenuItem(value: 'chronic', child: Text('Chronic Condition')),
                  DropdownMenuItem(value: 'medication', child: Text('Current Medication')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (value) => setState(() => selectedType = value!),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g., Penicillin allergy, Diabetes Type 2',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedSeverity,
                decoration: const InputDecoration(
                  labelText: 'Severity',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'mild', child: Text('Mild')),
                  DropdownMenuItem(value: 'moderate', child: Text('Moderate')),
                  DropdownMenuItem(value: 'severe', child: Text('Severe')),
                  DropdownMenuItem(value: 'critical', child: Text('Critical')),
                ],
                onChanged: (value) => setState(() => selectedSeverity = value!),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Visible to First Responders'),
                subtitle: const Text('Show in emergency QR code'),
                value: isPublic,
                onChanged: (value) => setState(() => isPublic = value),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    if (descriptionController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a description')),
                      );
                      return;
                    }
                    await _addCondition(
                      context,
                      ref,
                      selectedType,
                      descriptionController.text,
                      selectedSeverity,
                      isPublic,
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Add Condition'),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addCondition(
    BuildContext context,
    WidgetRef ref,
    String type,
    String description,
    String severity,
    bool isPublic,
  ) async {
    try {
      final supabase = Supabase.instance.client;
      final userId = supabase.auth.currentUser?.id;
      
      if (userId == null) return;
      
      // Get patient id
      final patientResult = await supabase
          .from('patients')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      
      if (patientResult == null) {
        // Create patient record if it doesn't exist
        final newPatient = await supabase
            .from('patients')
            .insert({'user_id': userId})
            .select('id')
            .single();
        
        await supabase.from('medical_conditions').insert({
          'patient_id': newPatient['id'],
          'condition_type': type,
          'description': description,
          'severity': severity,
          'is_public': isPublic,
        });
      } else {
        await supabase.from('medical_conditions').insert({
          'patient_id': patientResult['id'],
          'condition_type': type,
          'description': description,
          'severity': severity,
          'is_public': isPublic,
        });
      }
      
      ref.invalidate(medicalConditionsProvider);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Condition added successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _deleteCondition(BuildContext context, WidgetRef ref, String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Condition'),
        content: const Text('Are you sure you want to delete this condition?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await Supabase.instance.client
          .from('medical_conditions')
          .delete()
          .eq('id', id);
      
      ref.invalidate(medicalConditionsProvider);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Condition deleted')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

